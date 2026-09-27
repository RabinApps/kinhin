import Foundation

// MARK: - Forgejo adapter

/// Forgejo (Gitea's upstream) is wire-compatible with Gitea: same
/// `/api/v1` endpoints, same actions task queue, same gitea-runner binary.
/// The forge is therefore a thin re-brand of `GiteaForge` — different id,
/// name, and default account, identical behavior.
struct ForgejoForge: Forge {
    public let id: ForgeID = .forgejo
    public let name = "forgejo"
    public let account: String
    public let credentials: ForgeCredentials
    public let labels: [String]
    public let registration: ForgeRegistration = .sharedLongLived
    public let exitSemantics: ForgeExitSemantics = .idleGrace
    let client: GiteaClient
    let demandFloor: Int
    let registrationToken: String

    public init(
        credentials: ForgeCredentials, labels: [String], client: GiteaClient, demandFloor: Int = 0,
        registrationToken: String, account: String = "forgejo"
    ) {
        self.account = account
        self.credentials = credentials
        self.labels = labels
        self.client = client
        self.demandFloor = demandFloor
        self.registrationToken = registrationToken
    }

    /// Builds the forge from credentials (token mint doubles as the probe).
    public static func make(
        credentials: GiteaCredentials, labels: [String], demandFloor: Int = 0, account: String = "forgejo"
    ) async throws -> ForgejoForge {
        let client = GiteaClient(credentials: credentials)
        let token = try await client.fetchRegistrationToken()
        return ForgejoForge(
            credentials: .forgejo(token: credentials.token, scope: credentials.scope, instance: credentials.instance),
            labels: labels,
            client: client,
            demandFloor: demandFloor,
            registrationToken: token,
            account: account
        )
    }

    func registrationURL() -> String {
        switch credentials {
        case .forgejo(_, _, let instance): return instance
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
        let tasks = try await client.queuedTasks()
        if tasks.isEmpty, demandFloor > 0 {
            return (0..<demandFloor).map { _ in
                ForgeJob(name: "forgejo-task", runnerName: nil, repository: nil)
            }
        }
        return tasks.map { task in
            ForgeJob(name: task.name ?? "forgejo-task", runnerName: nil, repository: task.repository)
        }
    }

    func runningJobs() async throws -> [ForgeJob] {
        let tasks = try await client.runningTasks().filter { $0.runnerName != nil }
        if !tasks.isEmpty {
            return tasks.map { task in
                ForgeJob(name: task.name ?? "forgejo-task", runnerName: task.runnerName, repository: task.repository)
            }
        }
        return try await client.listRunners().filter { $0.status == "busy" }.map { runner in
            ForgeJob(name: "forgejo-task", runnerName: runner.name, repository: nil)
        }
    }
}
