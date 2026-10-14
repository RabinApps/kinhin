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
    /// Bitbucket Cloud Pipelines self-hosted runners; the scope is a
    /// workspace, or `workspace/repo` to serve one repository.
    case bitbucket

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

    /// GitHub credentials. `instance` is nil on github.com. `allowInsecureHTTP`
    /// is accepted so call sites can pass the account's flag alongside the
    /// instance, but this struct does not carry it: the scheme rule is enforced
    /// where the URL is used (`GitHubCredentials`, `GitHubClient`).
    public static func github(
        token: String, scope: String, instance: String? = nil, allowInsecureHTTP: Bool = false
    ) -> ForgeCredentials {
        ForgeCredentials(forge: .github, token: token, scope: scope, instance: instance)
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
    /// GitHub Runner Scale Set runners authenticate with a generated JIT
    /// config (the scale-set message API path). The config is generated per
    /// runner and passed to the in-VM bootstrap; the listener owns the
    /// scale-set session, not this registration method.
    case jitConfig
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

/// Unified forge surface the engine needs: one adapter per forge over that
/// forge's own client. All methods are scoped to the credentials the forge was
/// built with. Capabilities only some forges have live in sub-protocols
/// (`ForgeWithJITConfig`, `ForgeWithQueuedJobs`), not here.
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
    /// Scale-set (`.jitConfig`) forges do not use this path.
    func mintRegistrationToken() async throws -> String
    /// `mintRegistrationToken` plus the expiry the forge reported, so
    /// `RegistrationTokenCache` follows the real lifetime instead of a fixed
    /// TTL. Defaults to no expiry (the cache then falls back to its TTL).
    func mintRegistrationTokenExpiring() async throws -> (token: String, expiresAt: Date?)
    /// Per-runner credentials (`perRunner`): creates each named runner with
    /// the given labels and returns name → token.
    func registrationTokens(runnerNames: [String], labels: [String]) async throws -> [String: String]
    /// This scope's runners (name/id/status/busy), unified shape.
    func runners() async throws -> [ForgeRunner]
    /// `runners()` bypassing the forge's own short-lived list cache. The
    /// engine asks for it before acting on a runner being gone or idle. The
    /// default is `runners()` (forges without such a cache).
    func freshRunners() async throws -> [ForgeRunner]
    /// For a server with no runner list (Forgejo through v14): the number of
    /// jobs running anywhere in the scope, which no runner can be matched to.
    /// nil whenever `runners()` is authoritative (every other forge, and
    /// Gitea 1.24+). `fresh` bypasses the forge's short cache; ask for it
    /// before acting on "nothing is running".
    func unlistedRunnerActivity(fresh: Bool) async throws -> Int?
    /// Which of `names` the forge's own event stream reported finishing a job (the scale-set
    /// listener's `JobCompleted`). A short job can start and end between two runner-list reads, so
    /// the list alone never shows the runner; this is the evidence it ran. Empty by default.
    func runnersReportedFinished(_ names: [String]) async -> Set<String>
    func deleteRunner(id: String) async throws
    /// Jobs waiting for a runner (per-repo attribution when the API gives it).
    func queuedJobs() async throws -> [ForgeJob]
    /// Jobs currently executing (runner_name keyed), for running attribution.
    func runningJobs() async throws -> [ForgeJob]
    /// The API budget the forge last reported (nil: the forge reports none).
    var rateLimit: ForgeRateLimit? { get }
    /// The bytes of the repo's `.kinhin/config.yml`, else its `.kinhin.yml`, in
    /// `repository` at `ref` (nil `ref` = the default branch), or nil when the repo has neither. Forges without a file
    /// API return nil.
    func projectFile(repository: String, ref: String?) async throws -> Data?
    /// The live pipeline the runner named `runnerName` is executing (steps and
    /// their state), or nil when it runs no job or the forge can't tell.
    /// `repository` narrows the lookup where the forge needs it.
    func pipelineDetail(runnerName: String, repository: String?) async throws -> PipelineDetail?
    /// The output of `step` of `job` (the whole job when `step` is nil) as the
    /// forge has it so far, or nil when the forge can't provide it. `job` and
    /// `step` come from this forge's own `pipelineDetail`.
    func pipelineLog(job: PipelineJob, step: PipelineStep?) async throws -> PipelineLog?
}

/// Forges whose runner API separates queued from running work, so the engine
/// can push queued jobs back to the queue or drop them as skipped. The
/// engine dispatches on the concrete forge type, never on this protocol, so
/// adding a queue-capable forge only needs an implementation of these two
/// methods on that type.
public protocol ForgeWithQueuedJobs: Forge {
    /// Cancel the queued jobs matching the fleet's labels and re-queue them.
    func userRequeueQueuedJobs() async throws
    /// Drop the queued jobs matching the fleet's labels as skipped.
    func userSkipQueuedJobs() async throws
}

extension Forge {
    func mintRegistrationTokenExpiring() async throws -> (token: String, expiresAt: Date?) {
        (try await mintRegistrationToken(), nil)
    }

    func unlistedRunnerActivity(fresh: Bool) async throws -> Int? { nil }

    func runnersReportedFinished(_ names: [String]) async -> Set<String> { [] }

    func freshRunners() async throws -> [ForgeRunner] { try await runners() }

    public func pipelineDetail(runnerName: String, repository: String?) async throws -> PipelineDetail? { nil }

    public func pipelineLog(job: PipelineJob, step: PipelineStep?) async throws -> PipelineLog? { nil }

    /// Requeue the forge's queued jobs. The default is a no-op; forges with
    /// queue semantics override.
    func requeueQueuedJobs() async {}

    /// Drop the forge's queued jobs as done. The default is a no-op; forges
    /// with queue semantics override.
    func skipQueuedJobs() async {}

    public var account: String { id.rawValue }

    /// The scope this forge serves ("owner/name" or an org).
    public var scope: String { credentials.scope }

    /// Org scopes have no slash; "owner/name" is one repository.
    public var attributesByRepo: Bool { !scope.contains("/") }

    public var rateLimit: ForgeRateLimit? { nil }

    public func projectFile(repository: String, ref: String?) async throws -> Data? { nil }

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

    /// JIT configs for several named runners (`.jitConfig` forges only). A
    /// forge that is not a `ForgeWithJITConfig` has none to give, and the
    /// lifecycle layer only asks for `.jitConfig` accounts.
    public func jitRunnerTokens(names: [String], labels: [String]) async throws -> [String: String] {
        guard let jit = self as? any ForgeWithJITConfig else {
            throw EngineError.registrationFailed(vm: account, stderr: "JIT registration requires a scale-set forge")
        }
        return try await jit.jitConfigs(names: names, labels: labels)
    }
}

/// Forges whose runners register with a generated JIT config instead of a
/// registration token (`ForgeRegistration.jitConfig`: the GitHub scale-set
/// message API). Only the GitHub scale-set forge conforms.
public protocol ForgeWithJITConfig: Forge {
    /// A JIT config string for one scale-set runner.
    func jitRunnerConfig(name: String, labels: [String]) async throws -> String?
}

extension ForgeWithJITConfig {
    /// One config per named runner (runners the forge returns no config for are omitted).
    func jitConfigs(names: [String], labels: [String]) async throws -> [String: String] {
        var out: [String: String] = [:]
        for name in names {
            if let config = try await jitRunnerConfig(name: name, labels: labels) {
                out[name] = config
            }
        }
        return out
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
    /// Branch or tag the job runs at (nil when the forge doesn't expose it).
    public let ref: String?
    /// Commit the job runs at (nil when the forge doesn't expose it).
    public let sha: String?
    /// True when the job comes from a fork's pull request: its repo file is
    /// never honored.
    public let isFork: Bool
    /// The forge actually told us whether the job is a fork's. False when the
    /// API does not say (GitHub scale-set messages, Gitea and Forgejo queues).
    public let forkKnown: Bool
    /// Treat the job's code as untrusted: a fork's PR, or a job whose origin
    /// the forge does not reveal. Gates the shared cache and the repo file.
    public var isUntrusted: Bool { isFork || !forkKnown }
    /// The pool the forge already chose for this job: a scale-set job arrives
    /// on the scale set the workflow named in `runs-on:`, and that set is bound
    /// to one runtime. Overrides repo and workflow routes; nil for every
    /// other forge, which routes by labels and config.
    public let runtimeHint: RuntimeID?

    public init(
        name: String, runnerName: String?, repository: String?, labels: [String]? = nil, ref: String? = nil,
        sha: String? = nil, isFork: Bool = false, forkKnown: Bool = false, runtimeHint: RuntimeID? = nil
    ) {
        self.name = name
        self.runnerName = runnerName
        self.repository = repository
        self.labels = labels
        self.ref = ref
        self.sha = sha
        self.isFork = isFork
        self.forkKnown = forkKnown
        self.runtimeHint = runtimeHint
    }
}
