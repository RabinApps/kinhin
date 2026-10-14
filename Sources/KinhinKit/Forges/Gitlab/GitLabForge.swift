import Foundation
import Synchronization

// MARK: - GitLab adapter

/// Forge implementation for gitlab.com and self-managed GitLab (≥ 16).
///
/// GitLab has no registration token to share: each instance's runners are
/// created through the API (`POST /user/runners`) with their own
/// authentication token, then run one job (`gitlab-runner run-single
/// --max-builds 1`) and delete themselves, so the GitHub-style "every runner
/// came and went" watch applies. Jobs pick runners by tags, and GitLab hands a
/// job to a runner whose tags include every tag the job asks for, so a job is
/// kinhin's demand when its tags are a subset of the labels some pool of the
/// fleet registers runners with (`poolLabels`).
struct GitLabForge: Forge {
    let id: ForgeID = .gitlab
    let name = "gitlab"
    let account: String
    let credentials: ForgeCredentials
    let labels: [String]
    /// Every label some pool registers runners with; the demand filter. Empty
    /// (tests, a forge built outside the engine) falls back to `labels`.
    let poolLabels: [String]
    let registration: ForgeRegistration = .perRunner
    let exitSemantics: ForgeExitSemantics = .deregisters
    let client: GitLabClient
    let gitlabScope: GitLabScope
    let snapshot: GitLabRunnerSnapshot

    init(
        credentials: ForgeCredentials, labels: [String], poolLabels: [String] = [], client: GitLabClient,
        scope: GitLabScope, account: String = "gitlab", runnerListTTL: TimeInterval = 3
    ) {
        self.account = account
        self.credentials = credentials
        self.labels = labels
        self.poolLabels = poolLabels
        self.client = client
        self.gitlabScope = scope
        self.snapshot = GitLabRunnerSnapshot(ttl: runnerListTTL)
    }

    /// The same forge (client, scope and runner snapshot) with a new set of
    /// pool labels, for a hot config reload that changed the pools.
    func replacingPoolLabels(_ poolLabels: [String]) -> GitLabForge {
        GitLabForge(copying: self, poolLabels: poolLabels)
    }

    /// Demand filters by what the pools advertise, so the served labels replace the pool labels.
    func relabeled(fleetLabels: [String], servedLabels: [String]) -> any Forge {
        replacingPoolLabels(servedLabels)
    }

    private init(copying other: GitLabForge, poolLabels: [String]) {
        account = other.account
        credentials = other.credentials
        labels = other.labels
        self.poolLabels = poolLabels
        client = other.client
        gitlabScope = other.gitlabScope
        snapshot = other.snapshot
    }

    /// Builds the forge, resolving the scope up front (fails fast on a bad
    /// token, instance, or path).
    static func make(
        credentials: GitLabCredentials, labels: [String], poolLabels: [String] = [], account: String = "gitlab"
    ) async throws -> GitLabForge {
        let client = GitLabClient(credentials: credentials)
        let scope = try await client.resolveScope()
        return GitLabForge(
            credentials: .gitlab(token: credentials.token, scope: credentials.scope, instance: credentials.instance),
            labels: labels, poolLabels: poolLabels, client: client, scope: scope, account: account)
    }

    /// Group scopes aggregate several projects, so they attribute by project.
    var attributesByRepo: Bool { gitlabScope.isGroup }

    func registrationURL() -> String {
        var instance = client.credentials.instance
        while instance.hasSuffix("/") { instance.removeLast() }
        return instance
    }

    func mintRegistrationToken() async throws -> String {
        throw EngineError.registrationFailed(
            vm: account, stderr: "GitLab has no shared registration token; runners are created per instance")
    }

    /// Creates one runner per name. The tags are the pool's labels (fleet
    /// labels plus the runtime marker, minus what the pool's platform cannot
    /// serve), falling back to the account's own labels when the engine names
    /// no pool. Unioning the two would re-add labels routing removed (`macos`
    /// on a Linux VM, `arm64` on an amd64 container).
    func registrationTokens(runnerNames: [String], labels poolLabels: [String]) async throws -> [String: String] {
        let tags = poolLabels.isEmpty ? labels : poolLabels
        var tokens: [String: String] = [:]
        defer { snapshot.invalidate() }  // the new runners must show up in the next list
        for name in runnerNames {
            tokens[name] = try await client.createRunner(in: gitlabScope, name: name, tags: tags).token
        }
        return tokens
    }

    /// The scope's runners, named by description. Every instance's watch
    /// polls this each second, so the list is shared for a few seconds.
    func runners() async throws -> [ForgeRunner] {
        let runners = try await snapshot.runners { try await client.listRunners(in: gitlabScope) }
        let busy = snapshot.busyRunnerNames
        return runners.compactMap { runner in
            guard let name = runner.description else { return nil }
            return ForgeRunner(
                id: String(runner.id), name: name, busy: busy.contains(name), online: runner.hasContacted)
        }
    }

    /// The runner list read right now: the shared few-second snapshot is
    /// dropped first, so "the runner is gone" or "idle" is never decided on
    /// a list from before the event.
    func freshRunners() async throws -> [ForgeRunner] {
        snapshot.invalidate()
        return try await runners()
    }

    func deleteRunner(id: String) async throws {
        try await client.deleteRunner(id: try numericRunnerID(id))
        snapshot.invalidate()
    }

    func queuedJobs() async throws -> [ForgeJob] {
        try await client.jobs(.pending, in: gitlabScope).filter(isOurs).map {
            ForgeJob(
                name: $0.name, runnerName: nil, repository: $0.project, labels: $0.tags, ref: $0.ref, sha: $0.sha,
                isFork: $0.fromMergeRequest, forkKnown: true)
        }
    }

    func projectFile(repository: String, ref: String?) async throws -> Data? {
        try await client.projectFile(repository: repository, ref: ref)
    }

    /// Running jobs keyed by the runner (→ instance) executing them. Also
    /// refreshes which runners are busy, since GitLab's runner list does not
    /// say.
    func runningJobs() async throws -> [ForgeJob] {
        let jobs = try await client.jobs(.running, in: gitlabScope)
        snapshot.setRunning(jobs)
        return jobs.filter(isOurs).map {
            ForgeJob(
                name: $0.name, runnerName: $0.runnerDescription, repository: $0.project, labels: $0.tags,
                isFork: $0.fromMergeRequest, forkKnown: true)
        }
    }

    var rateLimit: ForgeRateLimit? { client.rateLimit }

    /// The job `runnerName` is executing. The running-jobs read fans out over
    /// every project of a group, so the result of the engine's own poll is
    /// reused while it is recent and still names the runner; only a miss
    /// reads again.
    private func runningJob(of runnerName: String) async throws -> GitLabJob? {
        if let cached = snapshot.recentRunning(maxAge: Self.runningJobsReuse),
            let job = cached.first(where: { $0.runnerDescription == runnerName })
        {
            return job
        }
        let jobs = try await client.jobs(.running, in: gitlabScope)
        snapshot.setRunning(jobs)
        return jobs.first { $0.runnerDescription == runnerName }
    }

    /// How long the poll's running-jobs result serves `pipelineDetail`.
    private static let runningJobsReuse: TimeInterval = 10

    /// The pipeline of the job `runnerName` is running, with its jobs. GitLab
    /// exposes no steps below a job, so the detail is job-level.
    func pipelineDetail(runnerName: String, repository: String?) async throws -> PipelineDetail? {
        guard let mine = try await runningJob(of: runnerName),
            let projectID = mine.projectID, let pipelineID = mine.pipelineID
        else { return nil }
        let (info, jobs) = try await client.pipeline(projectID: projectID, pipelineID: pipelineID)
        let mapped = jobs.map { job in
            PipelineJob(
                id: String(job.id), name: job.stage.map { "\($0) › \(job.name)" } ?? job.name,
                state: Self.state(job.status), startedAt: PipelineParsing.date(job.startedAt),
                finishedAt: PipelineParsing.date(job.finishedAt), url: job.webURL, isCurrent: job.id == mine.id,
                logRef: "\(projectID)|\(job.id)")
        }
        return PipelineDetail(
            forge: .gitlab, title: "Pipeline #\(pipelineID)", repository: mine.project, ref: info.ref ?? mine.ref,
            sha: info.sha ?? mine.sha, url: info.webURL, state: Self.state(info.status),
            startedAt: PipelineParsing.date(info.startedAt), jobs: mapped, granularity: .job)
    }

    /// A job's trace; GitLab has no steps below a job, so `step` is ignored.
    func pipelineLog(job: PipelineJob, step: PipelineStep?) async throws -> PipelineLog? {
        let parts = job.logRef?.split(separator: "|").compactMap { Int($0) } ?? []
        guard parts.count == 2 else { return nil }
        let (text, truncated) = PipelineLogText.clean(try await client.jobTrace(projectID: parts[0], jobID: parts[1]))
        return PipelineLog(text: text, scope: .job, truncated: truncated)
    }

    static func state(_ status: String?) -> PipelineStepState {
        switch status ?? "" {
        case "running": return .running
        case "success": return .succeeded
        case "failed": return .failed
        case "canceled", "canceling": return .cancelled
        case "skipped", "manual": return .skipped
        default: return .pending  // created, pending, waiting_for_resource, preparing, scheduled
        }
    }

    /// A job targets this fleet when every tag it asks for is one some pool
    /// advertises: GitLab runs a job on a runner whose tags are a superset of
    /// the job's. Untagged jobs never match (kinhin's runners do not run
    /// untagged jobs).
    func isOurs(_ job: GitLabJob) -> Bool {
        let served = Set((poolLabels.isEmpty ? labels : poolLabels).map { $0.lowercased() })
        return !job.tags.isEmpty && job.tags.allSatisfy { served.contains($0.lowercased()) }
    }
}

// MARK: - Runner snapshot

/// Short-lived shared runner list plus the last known busy set, so per-VM
/// watches polling every second cost one API call per few seconds.
final class GitLabRunnerSnapshot: Sendable {
    private let list: SharedListCache<GitLabRunner>
    private let busy = Mutex<(names: Set<String>, jobs: [GitLabJob], at: Date?)>(([], [], nil))

    init(ttl: TimeInterval) {
        self.list = SharedListCache(ttl: ttl)
    }

    func runners(fetch: @escaping @Sendable () async throws -> [GitLabRunner]) async throws -> [GitLabRunner] {
        try await list.elements(fetch: fetch)
    }

    var busyRunnerNames: Set<String> { busy.withLock { $0.names } }

    /// Records the scope's running jobs (and so which runners are busy).
    func setRunning(_ jobs: [GitLabJob]) {
        busy.withLock { $0 = (Set(jobs.compactMap(\.runnerDescription)), jobs, Date()) }
    }

    /// The last running-jobs read when it is younger than `maxAge`.
    func recentRunning(maxAge: TimeInterval) -> [GitLabJob]? {
        busy.withLock { state in
            guard let at = state.at, Date().timeIntervalSince(at) < maxAge else { return nil }
            return state.jobs
        }
    }

    func invalidate() {
        list.invalidate()
    }
}
