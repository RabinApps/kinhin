import Foundation

// MARK: - GitHub adapter

/// Wraps the existing GitHubServing client in the unified Forge protocol.
/// No GitHub behavior changes.
struct GitHubForge: Forge {
    let id: ForgeID = .github
    let name = "github"
    let account: String
    let credentials: ForgeCredentials
    let labels: [String]
    let registration: ForgeRegistration = .sharedShortLived
    let exitSemantics: ForgeExitSemantics = .deregisters
    let client: GitHubServing

    init(credentials: ForgeCredentials, labels: [String], client: GitHubServing, account: String = "github") {
        self.credentials = credentials
        self.labels = labels
        self.client = client
        self.account = account
    }

    /// Build from a GitHubCredentials (the legacy single-forge path).
    init(credentials: GitHubCredentials, labels: [String]) {
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

    func runners() async throws -> [ForgeRunner] {
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

    var rateLimit: ForgeRateLimit? { client.rateLimit }

    func runningJobs() async throws -> [ForgeJob] {
        try await client.runningJobs(matching: Set(labels)).map {
            ForgeJob(name: $0.name, runnerName: $0.runnerName, repository: $0.repository)
        }
    }
}
