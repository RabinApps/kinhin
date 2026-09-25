import Foundation

// MARK: - Forge identity & credentials

/// Which platform a VM (or credential set) belongs to.
public enum ForgeID: String, Codable, Sendable, CaseIterable {
    case github
    case gitea
}

/// Unified credential set across forges.
public enum ForgeCredentials: Sendable {
    case github(token: String, scope: String)
    case gitea(token: String, scope: String, instance: String)

    public var forge: ForgeID {
        switch self {
        case .github: return .github
        case .gitea: return .gitea
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

// MARK: - GitHub adapter

/// Wraps the existing GitHubServing client in the unified Forge protocol.
/// No GitHub behavior changes.
struct GitHubForge: Forge {
    public let id: ForgeID = .github
    public let name = "github"
    public let account: String
    public let credentials: ForgeCredentials
    public let labels: [String]
    let client: GitHubServing

    public init(credentials: ForgeCredentials, labels: [String], client: GitHubServing, account: String = "github") {
        self.credentials = credentials
        self.labels = labels
        self.client = client
        self.account = account
    }

    /// Build from a GitHubCredentials (the legacy single-forge path).
    public init(credentials: GitHubCredentials, labels: [String]) {
        self.init(
            credentials: .github(token: credentials.token, scope: credentials.scope), labels: labels,
            client: GitHubClient(credentials: credentials))
    }

    func registrationURL() -> String {
        switch credentials {
        case .github(_, let scope): return GitHubCredentials(token: "", scope: scope).configureURL
        default: return ""
        }
    }

    func mintRegistrationToken() async throws -> String {
        try await client.fetchRegistrationToken().token
    }

    public func runners() async throws -> [ForgeRunner] {
        try await client.listRunners().map { ForgeRunner(id: $0.id, name: $0.name, busy: $0.busy) }
    }

    func deleteRunner(id: Int) async throws {
        try await client.deleteRunner(id: id)
    }

    func queuedJobs() async throws -> [ForgeJob] {
        try await client.queuedJobs(matching: Set(labels)).map {
            ForgeJob(name: $0.name, runnerName: nil, repository: $0.repository, labels: $0.labels)
        }
    }

    func runningJobs() async throws -> [ForgeJob] {
        try await client.runningJobs(matching: Set(labels)).map {
            ForgeJob(name: $0.name, runnerName: $0.runnerName, repository: $0.repository)
        }
    }
}

// MARK: - Gitea adapter

/// Forge implementation for Gitea instances. Gitea's runner API differs from
/// GitHub's: registration tokens are long-lived (not 1 h), so the token is
/// captured at forge construction instead of minted per VM; queued demand is
/// a count (not a job list), so `queuedJobs` synthesizes attribution-less
/// placeholders and honors a floor (min_runners) when the queue looks empty —
/// the documented fallback for Gitea's thinner cross-scope reporting.
struct GiteaForge: Forge {
    public let id: ForgeID = .gitea
    public let name = "gitea"
    public let account: String
    public let credentials: ForgeCredentials
    public let labels: [String]
    let client: GiteaClient
    /// Demand floor: when the task-count endpoint reports 0 but the instance
    /// has busy runners, wait on the floor instead of scaling to zero.
    let demandFloor: Int
    /// Long-lived registration token captured at construction.
    let registrationToken: String

    public init(
        credentials: ForgeCredentials, labels: [String], client: GiteaClient, demandFloor: Int = 0,
        registrationToken: String, account: String = "gitea"
    ) {
        self.account = account
        self.credentials = credentials
        self.labels = labels
        self.client = client
        self.demandFloor = demandFloor
        self.registrationToken = registrationToken
    }

    /// Builds the forge from credentials, resolving the registration token
    /// up front (the same call the permission probe uses — fail fast here).
    public static func make(
        credentials: GiteaCredentials, labels: [String], demandFloor: Int = 0, account: String = "gitea"
    ) async throws
        -> GiteaForge
    {
        let client = GiteaClient(credentials: credentials)
        let token = try await client.fetchRegistrationToken()
        return GiteaForge(
            credentials: .gitea(token: credentials.token, scope: credentials.scope, instance: credentials.instance),
            labels: labels,
            client: client,
            demandFloor: demandFloor,
            registrationToken: token,
            account: account
        )
    }

    func registrationURL() -> String {
        switch credentials {
        case .gitea(_, _, let instance): return instance
        default: return ""
        }
    }

    func mintRegistrationToken() async throws -> String {
        registrationToken
    }

    public func runners() async throws -> [ForgeRunner] {
        try await client.listRunners().map { runner in
            ForgeRunner(id: runner.id, name: runner.name, busy: runner.status == "busy")
        }
    }

    func deleteRunner(id: Int) async throws {
        try await client.deleteRunner(id: id)
    }

    func queuedJobs() async throws -> [ForgeJob] {
        var count = try await client.queuedTaskCount()
        if count == 0, demandFloor > 0 {
            count = demandFloor
        }
        return (0..<count).map { _ in ForgeJob(name: "gitea-task", runnerName: nil, repository: nil) }
    }

    func runningJobs() async throws -> [ForgeJob] {
        // Gitea's runner list carries busy state; per-runner job attribution
        // is not exposed uniformly across versions, so running attribution
        // for Gitea VMs comes from the busy flag in the lifecycle watch.
        []
    }
}

// MARK: - Forge factory

/// Builds Forge instances from credentials. Injectable in tests; production
/// wiring returns the platform clients.
struct ForgeFactory: Sendable {
    public var make: @Sendable (ForgeCredentials, [String], Int) async throws -> Forge

    public init(make: @escaping @Sendable (ForgeCredentials, [String], Int) async throws -> Forge) {
        self.make = make
    }

    public static var live: ForgeFactory {
        ForgeFactory { credentials, labels, floor in
            switch credentials {
            case .github:
                return GitHubForge(
                    credentials: credentials, labels: labels,
                    client: GitHubClient(
                        credentials: GitHubCredentials(token: token(of: credentials), scope: scope(of: credentials))))
            case .gitea(let token, let scope, let instance):
                let gitea = GiteaCredentials(token: token, scope: scope, instance: instance)
                return try await GiteaForge.make(credentials: gitea, labels: labels, demandFloor: floor)
            }
        }
    }

    static func token(of credentials: ForgeCredentials) -> String {
        switch credentials {
        case .github(let token, _): return token
        case .gitea(let token, _, _): return token
        }
    }

    static func scope(of credentials: ForgeCredentials) -> String {
        switch credentials {
        case .github(_, let scope): return scope
        case .gitea(_, let scope, _): return scope
        }
    }
}

// MARK: - Demand merging (multi-forge autoscaler)

enum ForgeDemand {
    /// Merge queued jobs across forges into repo → count. Each contributing
    /// forge carries `attribution: Bool` — a repo-scoped forge suppresses its
    /// breakdown (it would carry no information), org-scoped forges keep it.
    static func mergeQueueByRepo(_ perForge: [ForgeID: (attribution: Bool, jobs: [ForgeJob])]) -> [String: Int]? {
        merge(perForge)
    }

    /// Account-keyed variant (the engine keys demand by account name).
    static func mergeQueueByRepo(_ perForge: [String: (attribution: Bool, jobs: [ForgeJob])]) -> [String: Int]? {
        merge(perForge)
    }

    private static func merge<Key: Hashable>(_ perForge: [Key: (attribution: Bool, jobs: [ForgeJob])])
        -> [String: Int]?
    {
        var merged: [String: Int] = [:]
        var any = false
        for (forge, entry) in perForge where entry.attribution {
            any = true
            for job in entry.jobs {
                if let repo = job.repository {
                    merged[repo, default: 0] += 1
                }
            }
        }
        return any ? merged : nil
    }

    /// Pick the platform for a new VM: the attached forge with the largest
    /// unmet demand (queued jobs minus VMs already serving it). Ties prefer
    /// GitHub (the original platform): it is evaluated first and later
    /// forges need strictly greater unmet demand to take over.
    static func assignPlatform(demand: [ForgeID: Int], active: [ForgeID: Int], attached: Set<ForgeID>) -> ForgeID {
        var best: ForgeID = .github
        var bestUnmet = Int.min
        let ordered = attached.sorted { a, b in
            if a == .github { return true }
            if b == .github { return false }
            return a.rawValue < b.rawValue
        }
        for forge in ordered {
            let unmet = (demand[forge] ?? 0) - (active[forge] ?? 0)
            if unmet > bestUnmet {
                bestUnmet = unmet
                best = forge
            }
        }
        return best
    }

    /// Account-keyed variant of `assignPlatform`: the account with the
    /// largest unmet demand wins; ties prefer the legacy `github` account,
    /// then alphabetical order. With nothing attached it returns "github".
    static func assignAccount(demand: [String: Int], active: [String: Int], attached: Set<String>) -> String {
        var best = ForgeID.github.rawValue
        var bestUnmet = Int.min
        let ordered = attached.sorted { a, b in
            if a == ForgeID.github.rawValue { return true }
            if b == ForgeID.github.rawValue { return false }
            return a < b
        }
        for account in ordered {
            let unmet = (demand[account] ?? 0) - (active[account] ?? 0)
            if unmet > bestUnmet {
                bestUnmet = unmet
                best = account
            }
        }
        return best
    }
}
