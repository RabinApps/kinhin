import Foundation

// MARK: - Credentials

/// One Bitbucket Cloud workspace, optionally narrowed to one repository:
/// `scope` is `<workspace>` or `<workspace>/<repo-slug>`. Bitbucket is hosted
/// only, so there is no instance URL. The token is a workspace or repository
/// access token (Bearer); app passwords are not accepted because their scopes
/// do not cover runners.
public struct BitbucketCredentials: Sendable {
    public static let apiBase = "https://api.bitbucket.org"

    public let token: String
    public let scope: String

    public init(token: String, scope: String) {
        self.token = token
        self.scope = scope
    }

    /// The workspace slug (before the first slash).
    var workspace: String {
        String(scope.split(separator: "/", maxSplits: 1, omittingEmptySubsequences: false).first ?? "")
    }

    /// The repository slug (after the first slash); empty on workspace scopes.
    var repository: String {
        let parts = scope.split(separator: "/", maxSplits: 1, omittingEmptySubsequences: false)
        return parts.count == 2 ? String(parts[1]) : ""
    }

    /// `<workspace>` or `<workspace>/<repo-slug>`: non-empty slugs of
    /// lowercase letters, digits, `-`, `_` and `.`.
    static func isValidScope(_ scope: String) -> Bool {
        let parts = scope.split(separator: "/", maxSplits: 1, omittingEmptySubsequences: false)
        guard (1...2).contains(parts.count) else { return false }
        return parts.allSatisfy { slug in
            !slug.isEmpty && slug.allSatisfy { $0.isLowercase || $0.isNumber || "-_.".contains($0) }
        }
    }

    /// The access-token scopes the fleet needs (they cover runner CRUD and
    /// pipeline/step reads); shown as guidance, since access tokens carry
    /// fixed scope bundles per kind.
    static let requiredScopes = [
        "runner (workspace tokens) or runner:write (repository tokens)",
        "pipeline (workspace tokens) or pipeline:read (repository tokens)",
    ]
}

// MARK: - Scope

/// Where the account's runners live: the whole workspace, or one repository.
/// Resolved (and verified to exist) when the forge is built.
enum BitbucketScope: Equatable, Sendable {
    case workspace(String)
    case repository(workspace: String, slug: String)

    init(credentials: BitbucketCredentials) {
        if credentials.repository.isEmpty {
            self = .workspace(credentials.workspace)
        } else {
            self = .repository(workspace: credentials.workspace, slug: credentials.repository)
        }
    }

    /// The runners endpoint base, `<workspace>` substituted.
    var runnerPath: String {
        switch self {
        case .workspace(let name):
            return "/2.0/workspaces/\(name)/pipelines-config/runners"
        case .repository(let workspace, let slug):
            return "/2.0/repositories/\(workspace)/\(slug)/pipelines-config/runners"
        }
    }

    /// The pipelines endpoint base, `<workspace>` substituted.
    var pipelinesPath: String {
        switch self {
        case .workspace(let name):
            return "/2.0/repositories/\(name)"
        case .repository(let workspace, let slug):
            return "/2.0/repositories/\(workspace)/\(slug)"
        }
    }

    /// "acme" or "acme/widget" — the demand log's repo attribution.
    var description: String {
        switch self {
        case .workspace(let name): return name
        case .repository(let workspace, let slug): return "\(workspace)/\(slug)"
        }
    }
}

// MARK: - Wire models

/// A self-hosted runner as Bitbucket reports it. `oauthClient` is only
/// present when the runner was just created — its secret is shown exactly
/// once, so the create response is the only chance to capture it.
struct BitbucketRunner: Decodable, Sendable, Equatable {
    let uuid: String
    let name: String
    let labels: [String]
    let status: String
    let oauthClient: OAuthClient?

    struct OAuthClient: Decodable, Sendable, Equatable {
        let id: String
        let secret: String?
    }

    enum CodingKeys: String, CodingKey {
        case uuid, name, labels
        case state, oauthClient = "oauth_client"
    }

    enum StateKeys: String, CodingKey {
        case status
    }

    init(
        uuid: String, name: String, labels: [String] = [], status: String = "OFFLINE",
        oauthClient: OAuthClient? = nil
    ) {
        self.uuid = uuid
        self.name = name
        self.labels = labels
        self.status = status
        self.oauthClient = oauthClient
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        uuid = try container.decode(String.self, forKey: .uuid)
        name = try container.decode(String.self, forKey: .name)
        labels = try container.decodeIfPresent([String].self, forKey: .labels) ?? []
        status =
            try container.nestedContainer(keyedBy: StateKeys.self, forKey: .state)
            .decodeIfPresent(String.self, forKey: .status) ?? "OFFLINE"
        oauthClient = try container.decodeIfPresent(OAuthClient.self, forKey: .oauthClient)
    }

    var isOnline: Bool { status == "ONLINE" }
}

/// A pipeline as the repo's `/pipelines` list reports it.
struct BitbucketPipeline: Decodable, Sendable, Equatable {
    let uuid: String
    let repository: String
    let stateName: String

    struct Repository: Decodable, Sendable, Equatable {
        let fullName: String

        enum CodingKeys: String, CodingKey {
            case fullName = "full_name"
        }
    }

    init(uuid: String, repository: String, stateName: String) {
        self.uuid = uuid
        self.repository = repository
        self.stateName = stateName
    }

    enum CodingKeys: String, CodingKey {
        case uuid, repository, state
    }

    enum StateKeys: String, CodingKey {
        case name
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        uuid = try container.decode(String.self, forKey: .uuid)
        repository = try container.decode(Repository.self, forKey: .repository).fullName
        stateName =
            try container.nestedContainer(keyedBy: StateKeys.self, forKey: .state)
            .decodeIfPresent(String.self, forKey: .name) ?? ""
    }
}

/// A step of a pipeline, with the `runs-on` labels it asked for. Steps that
/// run on Atlassian's infrastructure carry no `runs_on` and never match a
/// self-hosted runner.
struct BitbucketStep: Decodable, Sendable, Equatable {
    let uuid: String
    let name: String?
    let stateName: String
    let runsOn: [String]

    init(uuid: String, name: String? = nil, stateName: String, runsOn: [String] = []) {
        self.uuid = uuid
        self.name = name
        self.stateName = stateName
        self.runsOn = runsOn
    }

    enum CodingKeys: String, CodingKey {
        case uuid, name, state
        case runsOn = "runs_on"
    }

    enum StateKeys: String, CodingKey {
        case name
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        uuid = try container.decode(String.self, forKey: .uuid)
        name = try container.decodeIfPresent(String.self, forKey: .name)
        stateName =
            try container.nestedContainer(keyedBy: StateKeys.self, forKey: .state)
            .decodeIfPresent(String.self, forKey: .name) ?? ""
        runsOn = try container.decodeIfPresent([String].self, forKey: .runsOn) ?? []
    }

    var isWaitingForRunner: Bool { stateName == "PENDING" }
    var isRunning: Bool { stateName == "IN_PROGRESS" }
}

/// A step waiting for or running on a self-hosted runner, attributed to its
/// repository.
public struct BitbucketJob: Sendable, Equatable {
    public let name: String
    /// The `runs-on` labels the step asked for (the routing signal).
    public let runsOn: [String]
    /// "workspace/repo" the pipeline belongs to.
    public let repository: String
    public let isRunning: Bool

    init(step: BitbucketStep, repository: String, isRunning: Bool) {
        self.name = step.name ?? step.uuid
        self.runsOn = step.runsOn
        self.repository = repository
        self.isRunning = isRunning
    }
}

// MARK: - Errors

enum BitbucketError: LocalizedError, Equatable {
    case unauthorized
    case forbidden(String)
    case notFound(String)
    case http(Int, String)
    case decoding(String)
    case invalidScope(String)
    case scopeNotFound(String)
    case missingOAuthClientSecret(String)

    var errorDescription: String? {
        switch self {
        case .unauthorized:
            return "Bitbucket rejected the access token (401): expired, revoked, or mistyped. "
                + "Fix: kinhin auth set NAME with a new token"
        case .forbidden(let why):
            return "Bitbucket forbidden (403): \(why). The token must belong to the workspace the scope names"
        case .notFound(let what):
            return "Bitbucket returned 404 for \(what): check the workspace and repository slugs"
        case .http(let code, let body):
            return "Bitbucket HTTP \(code): \(body)"
        case .decoding(let why):
            return "Could not decode Bitbucket response: \(why)"
        case .invalidScope(let scope):
            return "invalid Bitbucket scope '\(scope)': use '<workspace>' or '<workspace>/<repo-slug>'"
        case .scopeNotFound(let scope):
            return "no Bitbucket workspace or repository '\(scope)': check the slugs and that the token can see them"
        case .missingOAuthClientSecret(let name):
            return
                "Bitbucket created runner '\(name)' but did not return its OAuth client secret: the secret is shown "
                + "only once, so delete the runner on the forge and let kinhin create it again"
        }
    }
}
