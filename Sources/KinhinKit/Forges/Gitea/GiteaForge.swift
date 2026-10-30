import Foundation
import Synchronization

// MARK: - Runner-list discovery

/// Whether the server answers `GET …/actions/runners`. Gitea 1.24+ does; Gitea < 1.24 and Forgejo through at least
/// v14 answer 404 (docs/forges/gitea.md). The first 404 is remembered so the endpoint is not asked again on every
/// poll, and asked once more after `recheckAfter` (a server upgrade).
///
/// A reference type so the copies of the forge struct share one answer.
final class RunnerListSupport: Sendable {
    private let absentSince = Mutex<ContinuousClock.Instant?>(nil)
    private let recheckAfter: Duration

    init(recheckAfter: Duration = .seconds(600)) { self.recheckAfter = recheckAfter }

    /// True while the list is known to be absent.
    var isAbsent: Bool {
        absentSince.withLock { since in
            guard let started = since else { return false }
            if ContinuousClock.now - started >= recheckAfter {
                since = nil
                return false
            }
            return true
        }
    }

    func markAbsent() { absentSince.withLock { $0 = ContinuousClock.now } }
    func markPresent() { absentSince.withLock { $0 = nil } }
}

/// The scope's running-task count for forges with no runner list, read at most once per `ttl` unless asked fresh.
final class ScopeActivityCache: Sendable {
    private struct Entry {
        var count: Int
        var at: ContinuousClock.Instant
    }

    // The cached answer, nil until the first fetch.
    private let entry = Mutex<Entry?>(nil)
    private let ttl: Duration

    init(ttl: Duration = .seconds(3)) { self.ttl = ttl }

    func cached() -> Int? {
        entry.withLock { entry in
            guard let entry, ContinuousClock.now - entry.at < ttl else { return nil }
            return entry.count
        }
    }

    func store(_ count: Int) { entry.withLock { $0 = Entry(count: count, at: ContinuousClock.now) } }
}

// MARK: - Gitea-family adapter

/// Forge implementation for Gitea and Forgejo instances (Forgejo is Gitea's
/// wire-compatible upstream: same `/api/v1`, task queue and gitea-runner, so
/// only the id and name differ, both taken from the credentials).
///
/// Gitea's runner API differs from
/// GitHub's: registration tokens are long-lived (not 1 h), so the token is
/// captured at forge construction instead of minted per VM.
///
/// Queued demand uses the server's own queue endpoint when it exists
/// (`/actions/jobs?status=queued` on Gitea 1.25+, `/actions/runners/jobs`
/// on Forgejo 11+) and falls back to the task-queue shape on older servers.
/// A `min_runners` floor applies only on servers without that endpoint — the
/// old task-queue path still needs it because those servers report a count,
/// not a real queue — never overriding a legitimate zero.
struct GiteaForge: Forge {
    let id: ForgeID
    var name: String { id.rawValue }
    let account: String
    let credentials: ForgeCredentials
    let labels: [String]
    /// Every label some pool of the fleet registers runners with (`ForgeBuild.poolLabels`). Forgejo lists only the
    /// waiting jobs whose `runs-on` fits inside the labels it is asked about, so the demand query must name what the
    /// runners really advertise: with the account's labels alone (default `macos:host`) a job asking for
    /// `[self-hosted, linux]` or a Tart pool's `linux` was never seen. A `var` so a hot reload swaps it on a copy
    /// that keeps the shared caches below.
    var poolLabels: [String] = []
    let registration: ForgeRegistration = .sharedLongLived
    let exitSemantics: ForgeExitSemantics = .idleGrace
    let client: GiteaClient
    /// Demand floor: when the task-count endpoint reports 0 but the instance
    /// has busy runners, wait on the floor instead of scaling to zero.
    let demandFloor: Int
    /// Long-lived registration token captured at construction.
    let registrationToken: String
    /// What this server turned out to offer (shared by the copies of the forge).
    let runnerListSupport = RunnerListSupport()
    let scopeActivity: ScopeActivityCache

    init(
        credentials: ForgeCredentials, labels: [String], client: GiteaClient, demandFloor: Int = 0,
        registrationToken: String, account: String? = nil, activityTTL: Duration = .seconds(3)
    ) {
        scopeActivity = ScopeActivityCache(ttl: activityTTL)
        id = credentials.forge == .forgejo ? .forgejo : .gitea
        self.account = account ?? id.rawValue
        self.credentials = credentials
        self.labels = labels
        self.client = client
        self.demandFloor = demandFloor
        self.registrationToken = registrationToken
    }

    /// Builds the forge from credentials, resolving the registration token
    /// up front (the same call the permission probe uses — fail fast here).
    static func make(
        forge: ForgeID = .gitea, credentials: GiteaCredentials, labels: [String], poolLabels: [String] = [],
        demandFloor: Int = 0, account: String? = nil
    ) async throws -> GiteaForge {
        let client = GiteaClient(credentials: credentials.with(forge: forge))
        let token = try await client.fetchRegistrationToken()
        var built = GiteaForge(
            credentials: ForgeCredentials(
                forge: forge, token: credentials.token, scope: credentials.scope, instance: credentials.instance),
            labels: labels,
            client: client,
            demandFloor: demandFloor,
            registrationToken: token,
            account: account
        )
        built.poolLabels = poolLabels
        return built
    }

    /// The labels the queue is asked about: the account's own plus every pool's.
    var demandLabels: [String] {
        var result = labels
        for label in poolLabels where !result.contains(label) { result.append(label) }
        return result
    }

    /// The queue is asked about the account's labels plus every pool's, so the served labels replace the pool
    /// labels (the account's own `labels:` change only with an engine rebuild).
    func relabeled(fleetLabels: [String], servedLabels: [String]) -> any Forge {
        var copy = self
        copy.poolLabels = servedLabels
        return copy
    }

    func registrationURL() -> String {
        credentials.instance ?? ""
    }

    /// Placeholder job name when the instance reports none ("gitea-task").
    private var taskName: String { "\(name)-task" }

    func mintRegistrationToken() async throws -> String {
        registrationToken
    }

    func runners() async throws -> [ForgeRunner] {
        // No list on this server: nothing to report; the engine reads `unlistedRunnerActivity` instead.
        (try await listedRunners() ?? []).map { runner in
            ForgeRunner(id: String(runner.id), name: runner.name, busy: runner.isBusy)
        }
    }

    /// The server's runner list, or nil when it has none (a 404 is remembered, see `RunnerListSupport`).
    private func listedRunners() async throws -> [GiteaRunner]? {
        if runnerListSupport.isAbsent { return nil }
        do {
            let runners = try await client.listRunners()
            runnerListSupport.markPresent()
            return runners
        } catch ForgeAPIError.notFound {
            runnerListSupport.markAbsent()
            Log.info(name, "this server has no runner list (Gitea < 1.24, Forgejo); watching running tasks instead")
            return nil
        }
    }

    /// With no runner list the forge cannot say which runner runs what, only whether any task of the scope is
    /// running (Forgejo's task entries carry no runner name). The count is for the whole scope, so the engine treats
    /// every instance of the account as busy while it is above zero.
    func unlistedRunnerActivity(fresh: Bool) async throws -> Int? {
        guard runnerListSupport.isAbsent else { return nil }
        if !fresh, let cached = scopeActivity.cached() { return cached }
        let count = try await client.activeTaskCount()
        scopeActivity.store(count)
        return count
    }

    func deleteRunner(id: String) async throws {
        try await client.deleteRunner(id: try numericRunnerID(id))
    }

    func queuedJobs() async throws -> [ForgeJob] {
        // Preferred: the server's own queue endpoint when it exists (Gitea
        // 1.25+, Forgejo 11+). It reports real queued jobs, so the floor is
        // not needed there.
        if let jobs = try? await client.queuedJobs(runnerLabels: demandLabels), !jobs.isEmpty {
            return jobs
        }
        // Older servers without that endpoint: fall back to the task queue.
        // A failed request propagates; an empty-but-valid answer holds the
        // floor only when the server needs that fallback.
        let tasks = try await client.queuedTasks()
        if tasks.isEmpty, demandFloor > 0 {
            // The endpoint answered with no entries (older Gitea reports only
            // a count): hold the floor instead of scaling to zero. A real
            // empty queue overrides the floor (0 tasks → 0 jobs).
            return (0..<demandFloor).map { _ in
                ForgeJob(name: taskName, runnerName: nil, repository: nil)
            }
        }
        return tasks.map { task in
            ForgeJob(
                name: task.name ?? taskName, runnerName: nil, repository: task.repository, ref: task.ref,
                sha: task.sha, correlation: task.correlation)
        }
    }

    func projectFile(repository: String, ref: String?) async throws -> Data? {
        try await client.projectFile(repository: repository, ref: ref)
    }

    /// The task `runnerName` is running. Gitea and Forgejo expose no stable
    /// public step list, so the detail is the one task (job-level).
    func pipelineDetail(runnerName: String, repository: String?) async throws -> PipelineDetail? {
        guard let task = try await client.runningTasks().first(where: { $0.runnerName == runnerName }) else {
            return nil
        }
        let name = task.name ?? taskName
        let started = PipelineParsing.date(task.startedAt)
        let job = PipelineJob(
            id: task.id.map(String.init) ?? name, name: name, state: .running, startedAt: started, url: task.url,
            isCurrent: true)
        return PipelineDetail(
            forge: id, title: task.title ?? task.runNumber.map { "Run #\($0)" } ?? name,
            repository: task.repository, ref: task.ref, sha: task.sha, url: task.url, state: .running,
            startedAt: started, jobs: [job], granularity: .job)
    }

    /// The finished task's verdict and times; Gitea and Forgejo have no step list below the task. The task's
    /// `updated_at` is its last write, so it stands for the end time.
    func jobOutcome(for correlation: JobCorrelation) async throws -> JobOutcome? {
        guard let taskID = correlation.jobID.flatMap(Int.init), let task = try await client.task(id: taskID) else {
            return nil
        }
        guard JobOutcome.isFinished(giteaStatus: task.status) else { return JobOutcome() }
        return JobOutcome(
            result: JobOutcome.result(giteaStatus: task.status), startedAt: PipelineParsing.date(task.startedAt),
            completedAt: PipelineParsing.date(task.updatedAt))
    }

    func runningJobs() async throws -> [ForgeJob] {
        // Preferred: running tasks keyed by runner_name (repo attribution
        // when the instance exposes it) — mirrors GitHub's running jobs.
        let tasks = try await client.runningTasks().filter { $0.runnerName != nil }
        if !tasks.isEmpty {
            return tasks.map { task in
                ForgeJob(
                    name: task.name ?? taskName, runnerName: task.runnerName, repository: task.repository,
                    correlation: task.correlation)
            }
        }
        // Fallback: busy runners carry per-VM attribution even where per-task
        // runner names are absent from the queue endpoint. A server with no
        // runner list has no per-VM attribution to give.
        return try await (listedRunners() ?? []).filter { $0.isBusy }.map { runner in
            ForgeJob(name: taskName, runnerName: runner.name, repository: nil)
        }
    }
}
