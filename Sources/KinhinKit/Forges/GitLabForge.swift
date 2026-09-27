import Foundation

// MARK: - GitLab adapter

/// Forge implementation for gitlab.com and self-managed GitLab (≥ 16).
///
/// GitLab has no registration token to share: each instance's runners are
/// created through the API (`POST /user/runners`) with their own
/// authentication token, then run one job (`gitlab-runner run-single
/// --max-builds 1`) and delete themselves, so the GitHub-style "every runner
/// came and went" watch applies. Jobs pick runners by tags: a job is kinhin's
/// demand when its tags include every one of the account's labels, the same
/// rule GitHub's `runs-on:` matching uses.
struct GitLabForge: Forge {
    public let id: ForgeID = .gitlab
    public let name = "gitlab"
    public let account: String
    public let credentials: ForgeCredentials
    public let labels: [String]
    public let registration: ForgeRegistration = .perRunner
    public let exitSemantics: ForgeExitSemantics = .deregisters
    let client: GitLabClient
    let gitlabScope: GitLabScope
    let snapshot: GitLabRunnerSnapshot

    init(
        credentials: ForgeCredentials, labels: [String], client: GitLabClient, scope: GitLabScope,
        account: String = "gitlab", runnerListTTL: TimeInterval = 3
    ) {
        self.account = account
        self.credentials = credentials
        self.labels = labels
        self.client = client
        self.gitlabScope = scope
        self.snapshot = GitLabRunnerSnapshot(ttl: runnerListTTL)
    }

    /// Builds the forge, resolving the scope up front (fails fast on a bad
    /// token, instance, or path).
    static func make(credentials: GitLabCredentials, labels: [String], account: String = "gitlab") async throws
        -> GitLabForge
    {
        let client = GitLabClient(credentials: credentials)
        let scope = try await client.resolveScope()
        return GitLabForge(
            credentials: .gitlab(token: credentials.token, scope: credentials.scope, instance: credentials.instance),
            labels: labels, client: client, scope: scope, account: account)
    }

    /// Group scopes aggregate several projects, so they attribute by project.
    public var attributesByRepo: Bool { gitlabScope.isGroup }

    func registrationURL() -> String {
        var instance = client.credentials.instance
        while instance.hasSuffix("/") { instance.removeLast() }
        return instance
    }

    func mintRegistrationToken() async throws -> String {
        throw EngineError.registrationFailed(
            vm: account, stderr: "GitLab has no shared registration token; runners are created per instance")
    }

    /// Creates one runner per name. The tags are the account's labels plus
    /// the pool's (runtime markers), so a pool-specific job only lands on a
    /// runner of that pool.
    func registrationTokens(runnerNames: [String], labels poolLabels: [String]) async throws -> [String: String] {
        var tags = labels
        for label in poolLabels where !tags.contains(label) { tags.append(label) }
        var tokens: [String: String] = [:]
        defer { snapshot.invalidate() }  // the new runners must show up in the next list
        for name in runnerNames {
            tokens[name] = try await client.createRunner(in: gitlabScope, name: name, tags: tags).token
        }
        return tokens
    }

    /// The scope's runners, named by description. Every instance's watch
    /// polls this each second, so the list is shared for a few seconds.
    public func runners() async throws -> [ForgeRunner] {
        let runners = try await snapshot.runners { try await client.listRunners(in: gitlabScope) }
        let busy = snapshot.busyRunnerNames
        return runners.compactMap { runner in
            guard let name = runner.description else { return nil }
            return ForgeRunner(id: runner.id, name: name, busy: busy.contains(name), online: runner.hasContacted)
        }
    }

    func deleteRunner(id: Int) async throws {
        try await client.deleteRunner(id: id)
        snapshot.invalidate()
    }

    func queuedJobs() async throws -> [ForgeJob] {
        try await client.jobs(.pending, in: gitlabScope).filter(isOurs).map {
            ForgeJob(name: $0.name, runnerName: nil, repository: $0.project, labels: $0.tags)
        }
    }

    /// Running jobs keyed by the runner (→ instance) executing them. Also
    /// refreshes which runners are busy, since GitLab's runner list does not
    /// say.
    func runningJobs() async throws -> [ForgeJob] {
        let jobs = try await client.jobs(.running, in: gitlabScope)
        snapshot.setBusy(Set(jobs.compactMap(\.runnerDescription)))
        return jobs.filter(isOurs).map {
            ForgeJob(name: $0.name, runnerName: $0.runnerDescription, repository: $0.project, labels: $0.tags)
        }
    }

    /// A job targets this fleet when its tags include every account label.
    /// Untagged jobs never do (kinhin's runners do not run untagged jobs).
    func isOurs(_ job: GitLabJob) -> Bool {
        !labels.isEmpty && Set(labels).isSubset(of: Set(job.tags))
    }
}

// MARK: - Runner snapshot

/// Short-lived shared runner list plus the last known busy set, so per-VM
/// watches polling every second cost one API call per few seconds.
final class GitLabRunnerSnapshot: Sendable {
    private struct State {
        var fetched: Date?
        var runners: [GitLabRunner] = []
        var busy: Set<String> = []
    }

    private let ttl: TimeInterval
    private let state = Mutex(State())

    init(ttl: TimeInterval) {
        self.ttl = ttl
    }

    func runners(fetch: () async throws -> [GitLabRunner]) async throws -> [GitLabRunner] {
        let ttl = ttl
        if let cached = state.withLock({ state -> [GitLabRunner]? in
            guard let fetched = state.fetched, Date().timeIntervalSince(fetched) < ttl else { return nil }
            return state.runners
        }) {
            return cached
        }
        let fresh = try await fetch()
        state.withLock {
            $0.fetched = Date()
            $0.runners = fresh
        }
        return fresh
    }

    var busyRunnerNames: Set<String> { state.withLock { $0.busy } }

    func setBusy(_ names: Set<String>) {
        state.withLock { $0.busy = names }
    }

    func invalidate() {
        state.withLock { $0.fetched = nil }
    }
}
