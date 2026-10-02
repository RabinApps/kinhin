import Foundation

// MARK: - Credentials

/// One GitLab instance + scope: a project (`group/project`) or a group
/// (`group` or `group/subgroup`). GitLab paths nest, so the scope's kind is
/// resolved against the API (`GitLabClient.resolveScope`), never guessed from
/// its slashes.
public struct GitLabCredentials: Sendable {
    public static let defaultInstance = "https://gitlab.com"

    public let token: String
    public let scope: String
    /// Instance base URL, e.g. "https://gitlab.com" or a self-managed
    /// "https://example.com/gitlab" (relative-root installs keep their path).
    public let instance: String
    /// The account opted in to plain `http://` (`allow_insecure_http`): the
    /// token then travels in cleartext. Redirect and pagination host checks
    /// still apply.
    public let allowInsecureHTTP: Bool

    public init(token: String, scope: String, instance: String? = nil, allowInsecureHTTP: Bool = false) {
        self.token = token
        self.scope = scope
        self.instance = instance ?? Self.defaultInstance
        self.allowInsecureHTTP = allowInsecureHTTP
    }

    /// An http(s) URL with a host. A path prefix is allowed; an `/api` suffix
    /// is not (the client appends `/api/v4`).
    static func validate(instance: String, allowInsecureHTTP: Bool = false) throws -> URL {
        guard let url = URL(string: instance),
            ForgeHTTP.permitsScheme(of: url, allowInsecureHTTP: allowInsecureHTTP),
            let host = url.host, !host.isEmpty,
            !url.path.split(separator: "/").contains("api")
        else {
            throw GitLabError.invalidInstance(instance)
        }
        return url
    }

    /// `group/sub/project`: one or more non-empty segments.
    static func isValidScope(_ scope: String) -> Bool {
        let segments = scope.split(separator: "/", omittingEmptySubsequences: false)
        return !segments.isEmpty && segments.allSatisfy { !$0.isEmpty }
    }
}

/// What a GitLab scope turned out to be.
public enum GitLabScope: Sendable, Equatable {
    case project(id: Int, path: String)
    case group(id: Int, path: String)

    var id: Int {
        switch self {
        case .project(let id, _), .group(let id, _): return id
        }
    }

    var isGroup: Bool {
        if case .group = self { return true }
        return false
    }
}

// MARK: - Wire models

/// A runner as `GET …/runners` reports it. `description` is the name kinhin
/// gives it (the instance id); `status` is online/offline/stale/never_contacted.
public struct GitLabRunner: Decodable, Sendable, Equatable {
    public let id: Int
    public let description: String?
    public let status: String?

    public init(id: Int, description: String?, status: String?) {
        self.id = id
        self.description = description
        self.status = status
    }

    /// The runner's agent has connected at least once.
    var hasContacted: Bool { status != "never_contacted" }
}

/// A CI job, attributed to the project it was read from.
public struct GitLabJob: Sendable, Equatable {
    public let id: Int
    public let name: String
    public let tags: [String]
    /// `path_with_namespace` of the job's project.
    public let project: String
    /// The runner executing the job (running jobs only).
    public let runnerDescription: String?
    /// Branch/tag and commit the job runs at.
    public let ref: String?
    public let sha: String?

    public init(
        id: Int, name: String, tags: [String], project: String, runnerDescription: String?, ref: String? = nil,
        sha: String? = nil
    ) {
        self.id = id
        self.name = name
        self.tags = tags
        self.project = project
        self.runnerDescription = runnerDescription
        self.ref = ref
        self.sha = sha
    }
}

/// `POST /user/runners` response: the new runner and its authentication
/// token (`glrt-…`), which the agent uses directly.
struct GitLabCreatedRunner: Decodable, Sendable, Equatable {
    let id: Int
    let token: String
}

// MARK: - Errors

enum GitLabError: LocalizedError, Equatable {
    case unauthorized
    case forbidden(String)
    case notFound(String)
    case http(Int, String)
    case decoding(String)
    case invalidInstance(String)
    case insufficientScopes([String])
    case unsupportedVersion(String)

    var errorDescription: String? {
        switch self {
        case .unauthorized:
            return "GitLab rejected the access token (401): expired, revoked, or wrong instance. "
                + "Fix: kinhin auth set NAME with a new token"
        case .forbidden(let why):
            return "GitLab forbidden (403): \(why). Creating runners needs Maintainer on a project or Owner on a group"
        case .notFound(let what):
            return "GitLab returned 404 for \(what): check the scope path and that the token can see it"
        case .http(let code, let body):
            return "GitLab HTTP \(code): \(body)"
        case .decoding(let why):
            return "Could not decode GitLab response: \(why)"
        case .invalidInstance(let url):
            return "invalid GitLab instance URL: \(url). Use https://gitlab.example.com (no /api suffix)"
        case .insufficientScopes(let missing):
            return "the GitLab token is missing scopes: \(missing.joined(separator: ", ")). "
                + "It needs create_runner, manage_runner and read_api"
        case .unsupportedVersion(let version):
            return "GitLab \(version) is too old: kinhin needs GitLab 16.0 or later (the runner creation API)"
        }
    }
}
