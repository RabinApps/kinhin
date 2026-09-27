import Foundation

// MARK: - Gitea adapter

/// Forge implementation for Gitea instances. Gitea's runner API differs from
/// GitHub's: registration tokens are long-lived (not 1 h), so the token is
/// captured at forge construction instead of minted per VM; queued demand
/// comes from the instance's task-queue entries (per-task repo attribution
/// when the instance exposes it) and honors a floor (min_runners) only when
/// the endpoint fails or reports no usable entries — the fallback for older
/// Gitea shapes, never overriding a legitimate zero.
struct GiteaForge: Forge {
    public let id: ForgeID = .gitea
    public let name = "gitea"
    public let account: String
    public let credentials: ForgeCredentials
    public let labels: [String]
    public let registration: ForgeRegistration = .sharedLongLived
    public let exitSemantics: ForgeExitSemantics = .idleGrace
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
        // Real task entries with per-task repo attribution. A failed request
        // propagates (the engine's poll handler logs it and keeps the previous
        // scaling state — the pre-attribution behavior); an empty-but-valid
        // answer holds the demand floor below.
        let tasks = try await client.queuedTasks()
        if tasks.isEmpty, demandFloor > 0 {
            // The endpoint answered with no entries (older Gitea reports only
            // a count): hold the floor instead of scaling to zero. A real
            // empty queue overrides the floor (0 tasks → 0 jobs).
            return (0..<demandFloor).map { _ in
                ForgeJob(name: "gitea-task", runnerName: nil, repository: nil)
            }
        }
        return tasks.map { task in
            ForgeJob(name: task.name ?? "gitea-task", runnerName: nil, repository: task.repository)
        }
    }

    func runningJobs() async throws -> [ForgeJob] {
        // Preferred: running tasks keyed by runner_name (repo attribution
        // when the instance exposes it) — mirrors GitHub's running jobs.
        let tasks = try await client.runningTasks().filter { $0.runnerName != nil }
        if !tasks.isEmpty {
            return tasks.map { task in
                ForgeJob(name: task.name ?? "gitea-task", runnerName: task.runnerName, repository: task.repository)
            }
        }
        // Fallback: busy runners carry per-VM attribution even where per-task
        // runner names are absent from the queue endpoint.
        return try await client.listRunners().filter { $0.status == "busy" }.map { runner in
            ForgeJob(name: "gitea-task", runnerName: runner.name, repository: nil)
        }
    }
}
