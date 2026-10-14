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

    private var workspace: String {
        switch self {
        case .workspace(let name): return name
        case .repository(let workspace, _): return workspace
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

    /// The pipelines endpoint base, `<workspace>` substituted. Workspace
    /// scopes combine it with a repo on the caller's side.
    var pipelinesPath: String {
        switch self {
        case .workspace(let name):
            return "/2.0/repositories/\(name)"
        case .repository(let workspace, let slug):
            return "/2.0/repositories/\(workspace)/\(slug)"
        }
    }

    /// The workspace's own endpoint (its UUID lives here).
    var workspacePath: String { "/2.0/workspaces/\(workspace)" }

    /// The repository's endpoint (its UUID lives in the payload).
    var repositoryPath: String? {
        switch self {
        case .workspace: return nil
        case .repository(let workspace, let slug): return "/2.0/repositories/\(workspace)/\(slug)"
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
    /// Shown by the pipeline view; nil on payloads without them.
    let buildNumber: Int?
    let refName: String?
    let commit: String?
    let createdOn: String?

    struct Target: Decodable, Sendable, Equatable {
        let refName: String?
        let commit: Commit?
        struct Commit: Decodable, Sendable, Equatable { let hash: String? }

        enum CodingKeys: String, CodingKey {
            case refName = "ref_name"
            case commit
        }
    }

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
        self.buildNumber = nil
        self.refName = nil
        self.commit = nil
        self.createdOn = nil
    }

    enum CodingKeys: String, CodingKey {
        case uuid, repository, state, target
        case buildNumber = "build_number"
        case createdOn = "created_on"
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
        buildNumber = try container.decodeIfPresent(Int.self, forKey: .buildNumber)
        createdOn = try container.decodeIfPresent(String.self, forKey: .createdOn)
        // Lenient: the target only names the ref and commit for display; a shape
        // Bitbucket varies by trigger reads as nil instead of dropping the pipeline.
        let target = try? container.decodeIfPresent(Target.self, forKey: .target)
        refName = target?.refName
        commit = target?.commit?.hash
    }
}

/// A step of a pipeline, with the `runs-on` labels it asked for. The public
/// API does not expose `runs_on` yet (the runner itself matches on the forge
/// side), so it decodes empty; `repository` is not part of the payload — the
/// client fills it with the repository it read the step from.
struct BitbucketStep: Decodable, Sendable, Equatable {
    let uuid: String
    let name: String?
    let stateName: String
    let runsOn: [String]
    /// "workspace/repo" the step's pipeline belongs to (set by the client).
    var repository: String?
    /// `state.result.name` once completed (SUCCESSFUL, FAILED, STOPPED, …).
    let resultName: String?
    /// `state.stage.name` when present (a PENDING step that is PAUSED or HALTED
    /// is not waiting for a runner).
    let stageName: String?
    let startedOn: String?
    let completedOn: String?

    init(
        uuid: String, name: String? = nil, stateName: String, runsOn: [String] = [], repository: String? = nil,
        stageName: String? = nil
    ) {
        self.stageName = stageName
        self.resultName = nil
        self.startedOn = nil
        self.completedOn = nil
        self.uuid = uuid
        self.name = name
        self.stateName = stateName
        self.runsOn = runsOn
        self.repository = repository
    }

    enum CodingKeys: String, CodingKey {
        case uuid, name, state
        case runsOn = "runs_on"
        case startedOn = "started_on"
        case completedOn = "completed_on"
    }

    enum StateKeys: String, CodingKey {
        case name, result, stage
    }

    struct Result: Decodable { let name: String? }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        uuid = try container.decode(String.self, forKey: .uuid)
        name = try container.decodeIfPresent(String.self, forKey: .name)
        stateName =
            try container.nestedContainer(keyedBy: StateKeys.self, forKey: .state)
            .decodeIfPresent(String.self, forKey: .name) ?? ""
        runsOn = try container.decodeIfPresent([String].self, forKey: .runsOn) ?? []
        repository = nil
        // Lenient: result and stage exist only on some states; their absence or
        // a shape change is nil, never a dropped step.
        resultName =
            try? container.nestedContainer(keyedBy: StateKeys.self, forKey: .state)  // lenient: see above
            .decodeIfPresent(Result.self, forKey: .result)?.name
        stageName =
            try? container.nestedContainer(keyedBy: StateKeys.self, forKey: .state)  // lenient: see above
            .decodeIfPresent(Result.self, forKey: .stage)?.name
        startedOn = try container.decodeIfPresent(String.self, forKey: .startedOn)
        completedOn = try container.decodeIfPresent(String.self, forKey: .completedOn)
    }

    var isQueued: Bool { stateName == "PENDING" }
    var isRunning: Bool { stateName == "IN_PROGRESS" }
}

/// A step waiting for or running on a self-hosted runner, attributed to its
/// repository. Which runner took a step is not public, so running jobs carry
/// no runner name; the runners' busy state comes from the running steps
/// instead (see `BitbucketForge`).
public struct BitbucketJob: Sendable, Equatable {
    public let name: String
    /// The `runs-on` labels the step asked for. The API payload carries none,
    /// so the forge fills them from the pipeline's `bitbucket-pipelines.yml`
    /// (empty: a cloud step, or unknown).
    public let runsOn: [String]
    public let stateName: String
    /// "workspace/repo" the pipeline belongs to.
    public let repository: String
    /// A PENDING step that is really waiting for a runner now, not a future
    /// step behind a running one or a paused/halted one.
    let isReady: Bool

    init(step: BitbucketStep, runsOn: [String]? = nil, isReady: Bool = true) {
        self.name = step.name ?? step.uuid
        self.runsOn = runsOn ?? step.runsOn
        self.stateName = step.stateName
        self.repository = step.repository ?? ""
        self.isReady = isReady
    }

    /// Waiting for a runner right now.
    var isQueued: Bool { stateName == "PENDING" && isReady }
    var isRunning: Bool { stateName == "IN_PROGRESS" }

    /// Whether the step runs on a self-hosted runner, the only kind this fleet
    /// can serve. Cloud steps (no `runs-on`) and Windows runners are not
    /// ours.
    var isSelfHosted: Bool {
        let labels = Set(runsOn.map { $0.lowercased() })
        return labels.contains("self.hosted") && !labels.contains("windows")
    }
}

/// A repository of the workspace with its last-activity timestamp, for the
/// "recently active repos first" demand poll.
struct BitbucketRepoRef: Decodable, Sendable, Equatable {
    let fullName: String
    /// Bitbucket's ISO-8601 string (`2024-05-01T12:34:56.789012+00:00`). Kept as
    /// text: a default `JSONDecoder` date strategy rejects it, which failed every
    /// workspace-scope poll.
    let updatedOn: String?

    enum CodingKeys: String, CodingKey {
        case fullName = "full_name"
        case updatedOn = "updated_on"
    }
}

// MARK: - Errors

/// Bitbucket-specific failures. The HTTP-shaped API errors (401/403/404/5xx,
/// decoding) come from the shared transport as `ForgeAPIError`.
enum BitbucketError: LocalizedError, Equatable {
    case invalidScope(String)
    case scopeNotFound(String)
    case missingOAuthClientSecret(String)
    /// A pagination `next` link that leaves the Bitbucket API host (or is not
    /// https).
    case untrustedPageLink(String)

    var errorDescription: String? {
        switch self {
        case .invalidScope(let scope):
            return "invalid Bitbucket scope '\(scope)': use '<workspace>' or '<workspace>/<repo-slug>'"
        case .scopeNotFound(let scope):
            return "no Bitbucket workspace or repository '\(scope)': check the slugs and that the token can see them"
        case .missingOAuthClientSecret(let name):
            return
                "Bitbucket created runner '\(name)' but did not return its OAuth client secret: the secret is shown "
                + "only once, so kinhin deleted the runner again and will create a new one on the next attempt"
        case .untrustedPageLink(let link):
            return "Bitbucket returned a pagination link outside its API (\(link)); refusing to send the token there"
        }
    }
}
