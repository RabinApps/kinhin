import Foundation

// MARK: - Forge identity & credentials

/// Which platform a VM (or credential set) belongs to. Case order is the
/// order forges are offered in (the app's pickers, CLI help, config errors).
public enum ForgeID: String, Codable, Sendable, CaseIterable {
    case github
    /// gitlab.com or a self-managed GitLab (≥ 16).
    case gitlab
    case gitea
    /// Gitea's upstream (wire-compatible: the same client, endpoints, and
    /// runner binary serve it — see `GiteaForge`).
    case forgejo
    /// buildkite.com (hosted only); the scope is `org/cluster`.
    case buildkite
    /// Azure Pipelines (Azure DevOps Services or Server); the instance is the
    /// organization URL and the scope an agent pool.
    case azuredevops

    /// The product name for UI and messages ("GitHub", "GitLab", …).
    public var displayName: String {
        switch self {
        case .github: return "GitHub"
        case .gitea: return "Gitea"
        case .forgejo: return "Forgejo"
        case .gitlab: return "GitLab"
        case .buildkite: return "Buildkite"
        case .azuredevops: return "Azure DevOps"
        }
    }
}

/// Unified credential set across forges: the forge, its token, the scope it
/// serves, and (self-hostable forges) the instance URL.
public struct ForgeCredentials: Sendable, Equatable {
    public let forge: ForgeID
    public let token: String
    /// "owner/name" (one repository) or an org name; any depth on GitLab.
    public let scope: String
    /// The instance base URL; nil on forges with a single hosted instance
    /// (GitHub).
    public let instance: String?

    public init(forge: ForgeID, token: String, scope: String, instance: String? = nil) {
        self.forge = forge
        self.token = token
        self.scope = scope
        self.instance = instance
    }

    public static func github(token: String, scope: String) -> ForgeCredentials {
        ForgeCredentials(forge: .github, token: token, scope: scope)
    }

    public static func gitea(token: String, scope: String, instance: String) -> ForgeCredentials {
        ForgeCredentials(forge: .gitea, token: token, scope: scope, instance: instance)
    }

    public static func forgejo(token: String, scope: String, instance: String) -> ForgeCredentials {
        ForgeCredentials(forge: .forgejo, token: token, scope: scope, instance: instance)
    }

    public static func gitlab(token: String, scope: String, instance: String) -> ForgeCredentials {
        ForgeCredentials(forge: .gitlab, token: token, scope: scope, instance: instance)
    }
}

// MARK: - Forge behavior

/// How a forge hands out runner registration credentials.
public enum ForgeRegistration: Sendable {
    /// One short-lived token shared by every runner (GitHub, ~1 h); the
    /// engine caches it per account.
    case sharedShortLived
    /// One long-lived token captured when the forge was built (Gitea family).
    case sharedLongLived
    /// A runner is created on the forge per runner name, each with its own
    /// authentication token (GitLab): see `Forge.registrationTokens`.
    case perRunner
}

/// What tells the engine that an ephemeral instance's jobs are done.
public enum ForgeExitSemantics: Sendable {
    /// Runners deregister themselves after their job (GitHub `--ephemeral`):
    /// the instance goes once every runner has come and gone.
    case deregisters
    /// Runner daemons stay registered (Gitea family): "busy, then idle for a
    /// grace period" is the job-done signal.
    case idleGrace
}

// MARK: - Protocol

/// Unified forge surface the engine needs. The GitHub implementation wraps
/// the existing `GitHubServing` client unchanged; Gitea gets its own client.
/// All methods are scoped to the credentials the forge was built with.
public protocol Forge: Sendable {
    var id: ForgeID { get }
    /// Human label for status lines ("github", "gitea").
    var name: String { get }
    var credentials: ForgeCredentials { get }
    /// The account this forge serves: "github"/"gitea" for the legacy
    /// `repo:`/`gitea:` sections, else the `accounts:` entry's name. Keys the
    /// engine's forge map and `VMRecord.platform`.
    var account: String { get }
    /// Labels the fleet matches jobs against on this forge.
    var labels: [String] { get }
    /// How runner registration credentials are obtained.
    var registration: ForgeRegistration { get }
    /// How the engine detects that an ephemeral instance is finished.
    var exitSemantics: ForgeExitSemantics { get }
    /// Whether queued jobs carry a useful per-repo breakdown (org/group
    /// scopes; a single-repo scope's breakdown would carry no information).
    var attributesByRepo: Bool { get }

    /// The URL the in-VM bootstrap uses to register (GitHub: configure URL;
    /// Gitea: instance URL).
    func registrationURL() -> String
    /// The shared registration token (`sharedShortLived`/`sharedLongLived`).
    func mintRegistrationToken() async throws -> String
    /// Per-runner credentials (`perRunner`): creates each named runner with
    /// the given labels and returns name → token.
    func registrationTokens(runnerNames: [String], labels: [String]) async throws -> [String: String]
    /// This scope's runners (name/id/status/busy), unified shape.
    func runners() async throws -> [ForgeRunner]
    func deleteRunner(id: String) async throws
    /// Jobs waiting for a runner (per-repo attribution when the API gives it).
    func queuedJobs() async throws -> [ForgeJob]
    /// Jobs currently executing (runner_name keyed), for running attribution.
    func runningJobs() async throws -> [ForgeJob]
    /// The API budget the forge last reported (nil: the forge reports none).
    var rateLimit: ForgeRateLimit? { get }
}

extension Forge {
    public var account: String { id.rawValue }

    /// The scope this forge serves ("owner/name" or an org).
    public var scope: String { credentials.scope }

    /// Org scopes have no slash; "owner/name" is one repository.
    public var attributesByRepo: Bool { !scope.contains("/") }

    public var rateLimit: ForgeRateLimit? { nil }

    /// The API id of a runner on a forge that numbers them (GitHub, the Gitea
    /// family, GitLab); `ForgeRunner.id` carries it as a string.
    func numericRunnerID(_ id: String) throws -> Int {
        guard let number = Int(id) else { throw EngineError.invalidRunnerID(forge: self.id, id: id) }
        return number
    }

    /// Shared-token forges: every runner uses the one token.
    public func registrationTokens(runnerNames: [String], labels: [String]) async throws -> [String: String] {
        let token = try await mintRegistrationToken()
        return Dictionary(uniqueKeysWithValues: runnerNames.map { ($0, token) })
    }
}

/// Forge-agnostic runner snapshot.
public struct ForgeRunner: Sendable, Equatable {
    /// The forge's own runner id: a number on GitHub, the Gitea family and
    /// GitLab (see `Forge.numericRunnerID`), a UUID elsewhere.
    public let id: String
    public let name: String
    public let busy: Bool
    /// False while the runner exists on the forge but its agent has never
    /// connected (forges that create runners before the agent starts). The
    /// ephemeral watch only counts a runner as registered once it is online.
    public let online: Bool

    public init(id: String, name: String, busy: Bool, online: Bool = true) {
        self.id = id
        self.name = name
        self.busy = busy
        self.online = online
    }
}

/// Forge-agnostic job snapshot.
public struct ForgeJob: Sendable, Equatable {
    public let name: String
    let runnerName: String?
    public let repository: String?
    /// Labels the job requested via `runs-on:` (when the forge exposes
    /// them) — the per-workflow routing signal.
    public let labels: [String]?

    public init(name: String, runnerName: String?, repository: String?, labels: [String]? = nil) {
        self.name = name
        self.runnerName = runnerName
        self.repository = repository
        self.labels = labels
    }
}
