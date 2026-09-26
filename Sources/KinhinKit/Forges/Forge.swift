import Foundation

// MARK: - Forge identity & credentials

/// Which platform a VM (or credential set) belongs to.
public enum ForgeID: String, Codable, Sendable, CaseIterable {
    case github
    case gitea
    /// Gitea's upstream (wire-compatible: the same client, endpoints, and
    /// runner binary serve it — see `ForgejoForge`).
    case forgejo
}

/// Unified credential set across forges.
public enum ForgeCredentials: Sendable {
    case github(token: String, scope: String)
    case gitea(token: String, scope: String, instance: String)
    case forgejo(token: String, scope: String, instance: String)

    public var forge: ForgeID {
        switch self {
        case .github: return .github
        case .gitea: return .gitea
        case .forgejo: return .forgejo
        }
    }
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

    /// The URL the in-VM bootstrap uses to register (GitHub: configure URL;
    /// Gitea: instance URL).
    func registrationURL() -> String
    /// Mint a short-lived runner registration token.
    func mintRegistrationToken() async throws -> String
    /// This scope's runners (name/id/status/busy), unified shape.
    func runners() async throws -> [ForgeRunner]
    func deleteRunner(id: Int) async throws
    /// Jobs waiting for a runner (per-repo attribution when the API gives it).
    func queuedJobs() async throws -> [ForgeJob]
    /// Jobs currently executing (runner_name keyed), for running attribution.
    func runningJobs() async throws -> [ForgeJob]
}

extension Forge {
    public var account: String { id.rawValue }
}

/// Forge-agnostic runner snapshot.
public struct ForgeRunner: Sendable, Equatable {
    public let id: Int
    public let name: String
    public let busy: Bool

    public init(id: Int, name: String, busy: Bool) {
        self.id = id
        self.name = name
        self.busy = busy
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

/// The forge a VM is currently serving.
enum VMPlatform: String, Codable, Sendable {
    case github
    case gitea
}
