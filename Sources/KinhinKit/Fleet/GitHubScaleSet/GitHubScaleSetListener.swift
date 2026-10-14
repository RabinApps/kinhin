import Foundation
import Synchronization

/// Owns one GitHub scale-set session and feeds demand back into the engine.
/// This is the replacement for the REST workflow-runs poll for accounts that opt
/// into scale-set mode.
public actor GitHubScaleSetListener {
    var session: GitHubScaleSetSession?
    /// Id of a session we stopped polling after a failure but never deleted; GitHub still treats it
    /// as active (409 on create) until it is refreshed or expires.
    var abandonedSessionId: String?
    var lastMessageId: String?
    var cachedSnapshot: GitHubScaleSetSnapshot?
    var pendingActions: [String: GitHubScaleSetJobEvent] = [:]
    /// Runners a `JobCompleted` named, newest last; bounded, since every runner name is used once.
    var finishedRunners: [String] = []
    static let finishedRunnersKept = 512
    var backOff: Duration = .seconds(1)
    var messagePollTask: Task<Void, Never>?
    var statisticsPollTask: Task<Void, Never>?
    var sessionRetryTask: Task<Void, Never>?
    var isRunning = false
    /// Whether this run already deleted a session left over from an earlier
    /// one (the store's record); done once, before the first create.
    var reapedStaleSession = false
    /// Consecutive 409s on session create, to tell a brief overlap from a
    /// session that something else is keeping alive.
    var conflictStreak = 0
    static let conflictsBeforeHint = 3

    let client: GitHubScaleSetServing
    let sessionStore: ScaleSetSessionStore?
    let scaleSetIdSupplier: () async throws -> Int
    let ownerName: String
    let fallbackRepository: String?
    let onDemandUpdate: @Sendable () async -> Void
    let pollInterval: Duration
    /// Job slots offered to GitHub on each poll. A closure so a config reload that changes the
    /// caps applies to the next poll instead of being frozen at attach time.
    nonisolated let maxCapacity: @Sendable () -> Int
    var cachedScaleSetId: Int?
    var cachedStatistics: GitHubScaleSetStatistics?
    var statisticsExpiresAt: Date?
    var _lastError: GitHubError?

    public init(
        client: GitHubScaleSetServing,
        scaleSetIdSupplier: @escaping @Sendable () async throws -> Int,
        ownerName: String,
        fallbackRepository: String? = nil,
        pollInterval: Duration = .seconds(2),
        maxCapacity: Int = 1_000,
        capacity: (@Sendable () -> Int)? = nil,
        onDemandUpdate: @escaping @Sendable () async -> Void = {},
        sessionStore: ScaleSetSessionStore? = nil
    ) {
        self.client = client
        self.sessionStore = sessionStore
        self.scaleSetIdSupplier = scaleSetIdSupplier
        self.ownerName = ownerName
        self.fallbackRepository = fallbackRepository
        self.pollInterval = pollInterval
        let fixed = max(0, maxCapacity)
        self.maxCapacity = capacity ?? { fixed }
        self.onDemandUpdate = onDemandUpdate
    }

    // MARK: - Lifecycle

    public func start() async {
        guard !isRunning else { return }
        isRunning = true
        await refreshSession()
        guard isRunning, !Task.isCancelled else { return }
        messagePollTask = Task { await pollLoop() }
        statisticsPollTask = Task { await statisticsPollLoop() }
    }

    public func stop() async {
        isRunning = false
        let messageTask = messagePollTask
        let statisticsTask = statisticsPollTask
        let retryTask = sessionRetryTask
        messageTask?.cancel()
        statisticsTask?.cancel()
        retryTask?.cancel()
        messagePollTask = nil
        statisticsPollTask = nil
        sessionRetryTask = nil
        await messageTask?.value
        await statisticsTask?.value
        await retryTask?.value
        if let sessionId = session?.sessionId ?? abandonedSessionId, let id = cachedScaleSetId {
            await bestEffort { [self] in try await client.deleteSession(scaleSetId: id, sessionId: sessionId) }
        }
        sessionStore?.clear()
        session = nil
        abandonedSessionId = nil
        reapedStaleSession = false
        conflictStreak = 0
        cachedSnapshot = nil
        pendingActions = [:]
        finishedRunners = []
        cachedScaleSetId = nil
        cachedStatistics = nil
        statisticsExpiresAt = nil
        _lastError = nil
    }

    /// The last error observed during listener maintenance.
    public func reportedError() -> GitHubError? { _lastError }

    // MARK: - Demand surface

    /// The candidate demand the engine should reconcile against. When the
    /// tracked event count is below the reported `totalAssignedJobs`, this
    /// synthesizes placeholder jobs so the returned count meets GitHub's
    /// reported demand; the placeholder names are not real queued workflow
    /// runs, and the REST queue operations intentionally skip them.
    public func queuedJobs() async throws -> [ForgeJob] {
        guard let snap = cachedSnapshot else { return [] }
        var jobs = resolveJobs(from: snap)
        if jobs.count < snap.statistics.totalAssignedJobs {
            let missing = snap.statistics.totalAssignedJobs - jobs.count
            jobs.append(contentsOf: synthesizePlaceholderJobs(upTo: missing, into: snap))
        }
        return jobs
    }

    /// Which of `names` a `JobCompleted` event named as the runner that ran the job.
    public func finishedRunners(among names: [String]) -> Set<String> {
        Set(names).intersection(finishedRunners)
    }

    /// Latest snapshot the listener has published. Before the first poll pass
    /// this is nil; after that it reflects the last computed demand.
    public func snapshot() -> GitHubScaleSetSnapshot? { cachedSnapshot }

    func resolveJobs(from snap: GitHubScaleSetSnapshot) -> [ForgeJob] {
        snap.trackedJobs.map { event in
            ForgeJob(
                name: event.jobDisplayName,
                runnerName: nil,
                repository: "\(event.ownerName)/\(event.repositoryName)",
                labels: event.requestLabels,
                ref: nil,
                sha: nil,
                isFork: false
            )
        }
    }

    func synthesizePlaceholderJobs(upTo count: Int, into snap: GitHubScaleSetSnapshot) -> [ForgeJob] {
        // After a restart no event is tracked yet, so an org-scoped listener has no repository to
        // attribute: the placeholders then carry none, but the demand they stand for still counts.
        let existingRepos: [String?] = snap.attributedRepos.isEmpty ? [nil] : snap.attributedRepos.sorted()
        var placeholders: [ForgeJob] = []
        var remaining = count
        var index = 0
        while remaining > 0 {
            let repo = existingRepos[index % existingRepos.count]
            placeholders.append(
                ForgeJob(
                    name: "scale-set placeholder \(snap.statistics.totalAssignedJobs)-\(placeholders.count)",
                    runnerName: nil,
                    repository: repo,
                    labels: [],
                    ref: nil,
                    sha: nil,
                    isFork: false
                )
            )
            remaining -= 1
            index += 1
        }
        return placeholders
    }

    func bestEffort(_ block: @escaping @Sendable () async throws -> Void) async {
        do { try await block() } catch { Log.warn("scaleset", "best-effort failed: \(error.localizedDescription)") }
    }

    // MARK: - Testing surface

    /// Replace the cached snapshot inputs for testability. This is the seam
    /// the unit tests use so the listener's demand path can be asserted without
    /// standing up a session and poll loop.
    func updateSnapshot(
        statistics: GitHubScaleSetStatistics,
        pendingActions: [String: GitHubScaleSetJobEvent]
    ) {
        self.pendingActions = pendingActions
        publishSnapshot(statistics: statistics)
    }
}
