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
enum ForgeAPIError: LocalizedError, CategorizedError, Equatable, Sendable {
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

    /// Credential and access problems are `.auth`; outages, throttling and
    /// malformed responses are not the token's fault.
    var category: ErrorCategory {
        switch self {
        case .unauthorized, .forbidden, .notFound: return .auth
        case .nonHTTPResponse, .decoding: return .runtime
        case .http(_, let code, _): return code == 401 || code == 403 ? .auth : .runtime
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
        let fix = "Fix: \(AuthFix.command(forge: forge, account: nil)) with a new token"
        switch forge {
        case .github:
            return
                "GitHub rejected the token (401): expired, revoked, or missing the required scopes. "
                + "Check it with `kinhin auth status`. \(fix)"
        case .gitlab:
            return "GitLab rejected the access token (401): expired, revoked, or wrong instance. \(fix)"
        case .gitea, .forgejo:
            return "\(forge.displayName) rejected the access token (401): expired, revoked, or wrong instance. \(fix)"
        case .buildkite:
            return "Buildkite rejected the API access token (401): expired, revoked, or mistyped. \(fix)"
        case .azuredevops:
            return "Azure DevOps rejected the personal access token (401): expired, revoked, or for another "
                + "organization. \(fix)"
        case .bitbucket:
            return "Bitbucket rejected the access token (401): expired, revoked, or mistyped. \(fix)"
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
            return
                "\(forge.displayName) returned 404 for \(what) — check the scope and that Actions are enabled on the instance"
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
/// the forge's auth scheme, one status→error mapping, and the shared
/// `ForgeRetryPolicy` (backoff with jitter on network errors and 5xx, waits for
/// `Retry-After` and spent rate limits, no retry of a plain 403). The clients
/// keep what is genuinely theirs — base-URL and path construction, pagination
/// and decoding — and hand the built URL here.
///
/// `GitHubClient` and `GitHubScaleSetClient` keep their own request building
/// (conditional GETs, rate-limit accounting, the Actions service URL) but run
/// the same `ForgeRetryPolicy`.
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
    /// Backoff base: retry n waits about `baseDelay * 2^(n-1)` seconds (jittered).
    var baseDelay: TimeInterval = 1
    /// How the retry loop waits (tests record the delays instead of sleeping).
    var sleep: ForgeRetryPolicy.Sleep = ForgeRetryPolicy().sleep

    var policy: ForgeRetryPolicy {
        ForgeRetryPolicy(retries: retries, baseDelay: baseDelay, sleep: sleep)
    }

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
        let policy = policy
        return try await policy.run {
            try await sendOnce(method, url, body: body, accept: accept, classify: classify, policy: policy)
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
        _ method: String, _ url: URL, body: Data?, accept: String, classify: Classifier?, policy: ForgeRetryPolicy
    ) async throws -> ForgeRetryPolicy.Attempt<(Data, HTTPURLResponse)> {
        var req = URLRequest(url: url)
        req.httpMethod = method
        let auth = authorization.header
        req.setValue(auth.value, forHTTPHeaderField: auth.field)
        req.setValue(accept, forHTTPHeaderField: "Accept")
        req.setValue(ForgeHTTP.userAgent, forHTTPHeaderField: "User-Agent")
        if let body {
            req.httpBody = body
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await session.data(for: req)
        } catch {
            ForgeRequestMetrics.record(forge: forge, status: nil)
            throw error
        }
        guard let http = response as? HTTPURLResponse else {
            return .retry(ForgeAPIError.nonHTTPResponse(forge: forge), after: nil)
        }
        ForgeRequestMetrics.record(forge: forge, status: http.statusCode)
        if let classify, let error = classify(http, data) {
            throw error
        }
        // Error bodies are truncated: a full HTML error page is not a message.
        let bodyText = { String(decoding: data.prefix(300), as: UTF8.self) }
        if (200...299).contains(http.statusCode) { return .done((data, http)) }
        let failure = Self.error(for: http, body: bodyText(), url: url, forge: forge)
        if case .retry(let after) = policy.verdict(for: http) { return .retry(failure, after: after) }
        throw failure
    }

    /// The status→error mapping shared by every forge.
    private static func error(for http: HTTPURLResponse, body: String, url: URL, forge: ForgeID) -> ForgeAPIError {
        switch http.statusCode {
        case 401: return .unauthorized(forge: forge)
        case 403: return .forbidden(forge: forge, why: body)
        case 404: return .notFound(forge: forge, what: url.path)
        default: return .http(forge: forge, code: http.statusCode, body: body)
        }
    }
}
