import Foundation

// MARK: - ForgeAPIError

/// The API failures every forge's REST surface can return, in one type, so
/// the shared `ForgeTransport` can throw it and the front ends can classify
/// it (`ErrorCategory`) without importing six per-forge enums. The per-forge
/// remediation hints live here too, one table instead of five.
///
/// Problems that are not HTTP-shaped — a malformed instance URL, missing
/// token scopes, an unknown pool — stay in the per-forge error enums, which
/// now only carry those forge-specific cases.
enum ForgeAPIError: LocalizedError, Equatable, Sendable {
    case nonHTTPResponse(forge: ForgeID)
    case unauthorized(forge: ForgeID)
    case forbidden(forge: ForgeID, why: String)
    case notFound(forge: ForgeID, what: String)
    case http(forge: ForgeID, code: Int, body: String)
    case decoding(forge: ForgeID, what: String)

    /// The forge the failure came from (also `.http(forge:, code: 0, …)`
    /// callers' identity for client-side validation failures).
    var forge: ForgeID {
        switch self {
        case .nonHTTPResponse(let forge), .unauthorized(let forge), .forbidden(let forge, _),
            .notFound(let forge, _), .http(let forge, _, _), .decoding(let forge, _):
            return forge
        }
    }

    var errorDescription: String? {
        switch self {
        case .nonHTTPResponse(let forge):
            return "\(forge.displayName) returned a non-HTTP response"
        case .unauthorized(let forge):
            return Self.unauthorizedMessage(forge)
        case .forbidden(let forge, let why):
            return Self.forbiddenMessage(forge, why: why)
        case .notFound(let forge, let what):
            return Self.notFoundMessage(forge, what: what)
        case .http(let forge, let code, let body):
            return "\(forge.displayName) HTTP \(code): \(body)"
        case .decoding(let forge, let what):
            return "Could not decode \(forge.displayName) response: \(what)"
        }
    }

    private static func unauthorizedMessage(_ forge: ForgeID) -> String {
        switch forge {
        case .github:
            return
                "GitHub rejected the token (401). Check it with `kinhin auth status` — it may be expired or lack the required scopes."
        case .gitlab:
            return
                "GitLab rejected the access token (401): expired, revoked, or wrong instance. Fix: kinhin auth set NAME with a new token"
        case .gitea, .forgejo:
            return
                "Gitea rejected the access token (401) — expired, revoked, or wrong instance. Fix: kinhin auth set --gitea"
        case .buildkite:
            return
                "Buildkite rejected the API access token (401): expired, revoked, or mistyped. Fix: kinhin auth set NAME with a new token"
        case .azuredevops:
            return "Azure DevOps rejected the personal access token (401): expired, revoked, or for another "
                + "organization. Fix: kinhin auth set NAME with a new token"
        case .bitbucket:
            return
                "Bitbucket rejected the access token (401): expired, revoked, or mistyped. Fix: kinhin auth set NAME with a new token"
        }
    }

    private static func forbiddenMessage(_ forge: ForgeID, why: String) -> String {
        let hint: String
        switch forge {
        case .gitlab:
            hint = " Creating runners needs Maintainer on a project or Owner on a group"
        case .buildkite:
            hint = " The token must belong to a member of the organization"
        case .azuredevops:
            hint = " The token needs the Agent Pools (Read & manage) scope"
        case .bitbucket:
            hint = " The token must belong to the workspace the scope names"
        case .github, .gitea, .forgejo:
            hint = ""
        }
        return "\(forge.displayName) forbidden (403): \(why)\(hint.isEmpty ? "" : ".\(hint)")"
    }

    private static func notFoundMessage(_ forge: ForgeID, what: String) -> String {
        switch forge {
        case .gitlab:
            return "GitLab returned 404 for \(what): check the scope path and that the token can see it"
        case .gitea, .forgejo:
            return "Gitea returned 404 for \(what) — check the scope and that Actions are enabled on the instance"
        case .buildkite:
            return "Buildkite returned 404 for \(what): check the organization slug and that the token can see it"
        case .azuredevops:
            return "Azure DevOps returned 404 for \(what): check the organization URL"
        case .bitbucket:
            return "Bitbucket returned 404 for \(what): check the workspace and repository slugs"
        case .github:
            return "GitHub returned 404 for \(what)"
        }
    }
}

// MARK: - ForgeTransport

/// One send/retry pipeline for the forge REST clients: request headers from
/// the forge's auth scheme, one status→error mapping, and retry with backoff
/// on transient failures (network errors, 429, 5xx). The clients keep what is
/// genuinely theirs — base-URL and path construction, pagination and
/// decoding — and hand the built URL here.
///
/// `GitHubClient` does not use this transport yet: its send adds conditional
/// GETs (ETag/304), rate-limit accounting and a 403 secondary-limit retry,
/// which would turn the shared pipeline into a GitHub-shaped one. It can
/// adopt the transport when those become `ForgeTransport` features.
struct ForgeTransport: Sendable {
    /// How a client authenticates: the header each forge's API expects.
    enum Authorization: Sendable {
        /// `Authorization: Bearer <token>` (Buildkite, Bitbucket).
        case bearer(String)
        /// `PRIVATE-TOKEN: <token>` (GitLab).
        case privateToken(String)
        /// `Authorization: token <token>` (Gitea, Forgejo).
        case giteaToken(String)
        /// `Authorization: Basic base64(":<PAT>")` — an empty user (Azure DevOps).
        case basicPassword(String)

        /// The header field and value for a request.
        var header: (field: String, value: String) {
            switch self {
            case .bearer(let token): return ("Authorization", "Bearer \(token)")
            case .privateToken(let token): return ("PRIVATE-TOKEN", token)
            case .giteaToken(let token): return ("Authorization", "token \(token)")
            case .basicPassword(let token):
                return ("Authorization", "Basic \(Data(":\(token)".utf8).base64EncodedString())")
            }
        }
    }

    let session: URLSession
    let forge: ForgeID
    let authorization: Authorization
    /// Attempts beyond the first on a transient failure (2 → up to 3 tries).
    var retries: Int = 2
    /// Backoff base: attempt n waits `baseDelay * 2^(n-1)` seconds.
    var baseDelay: TimeInterval = 1

    /// A forge-specific response classifier, consulted before the default
    /// status mapping. Returning non-nil throws that error (Azure's PAT
    /// sign-in pages); returning nil falls through to the shared mapping.
    typealias Classifier = @Sendable (HTTPURLResponse, Data) -> ForgeAPIError?

    /// Sends one request with retry on transient failures. `body` is sent
    /// with a JSON content type; `accept` overrides the Accept header.
    func send(
        _ method: String, _ url: URL, body: Data? = nil, accept: String = "application/json",
        classify: Classifier? = nil
    ) async throws -> (Data, HTTPURLResponse) {
        try await withTransientRetry(retries: retries, baseDelay: baseDelay, isTransient: Self.isTransient) {
            try await sendOnce(method, url, body: body, accept: accept, classify: classify)
        }
    }

    /// Whether `error` is worth another attempt: a transport or server-side
    /// failure, not a client mistake. Cancellation is never transient.
    static func isTransient(_ error: Error) -> Bool {
        switch error {
        case is CancellationError:
            return false
        case let api as ForgeAPIError:
            switch api {
            case .nonHTTPResponse: return true
            case .http(_, let code, _): return ForgeHTTP.isTransientStatus(code)
            case .unauthorized, .forbidden, .notFound, .decoding: return false
            }
        default:
            return ForgeHTTP.isTransientNetworkError(error)
        }
    }

    private func sendOnce(
        _ method: String, _ url: URL, body: Data?, accept: String, classify: Classifier?
    ) async throws -> (Data, HTTPURLResponse) {
        var req = URLRequest(url: url)
        req.httpMethod = method
        let auth = authorization.header
        req.setValue(auth.value, forHTTPHeaderField: auth.field)
        req.setValue(accept, forHTTPHeaderField: "Accept")
        req.setValue("Kinhin/1.0", forHTTPHeaderField: "User-Agent")
        if let body {
            req.httpBody = body
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        let (data, response) = try await session.data(for: req)
        guard let http = response as? HTTPURLResponse else {
            throw ForgeAPIError.nonHTTPResponse(forge: forge)
        }
        if let classify, let error = classify(http, data) {
            throw error
        }
        // Error bodies are truncated: a full HTML error page is not a message.
        let bodyText = { String(decoding: data.prefix(300), as: UTF8.self) }
        switch http.statusCode {
        case 200...299:
            return (data, http)
        case 401:
            throw ForgeAPIError.unauthorized(forge: forge)
        case 403:
            throw ForgeAPIError.forbidden(forge: forge, why: bodyText())
        case 404:
            throw ForgeAPIError.notFound(forge: forge, what: url.path)
        default:
            throw ForgeAPIError.http(forge: forge, code: http.statusCode, body: bodyText())
        }
    }
}
