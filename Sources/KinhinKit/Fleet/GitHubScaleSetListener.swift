import Foundation
import Synchronization

// MARK: - Listener snapshot

/// The demand snapshot a scale-set listener publishes to the engine.
public struct GitHubScaleSetSnapshot: Sendable, Equatable {
    /// Latest statistics from the scale-set API.
    public let statistics: GitHubScaleSetStatistics
    /// Queued job demand derived from tracked events. When the tracked count is
    /// lower than `statistics.totalAssignedJobs`, placeholder jobs are synthesized
    /// so `queuedJobs()` always meets GitHub's reported demand.
    ///
    /// Policies that decide VM counts off `queuedJobs()` should use the snapshot's
    /// `statistics.totalAssignedJobs` as the demand ceiling; the resolved job list
    /// may be a superset of the real demand when placeholders are synthesized.
    public let trackedJobs: [GitHubScaleSetJobEvent]
    /// Per-repo attribution from tracked events.
    public let attributedRepos: Set<String>
}

/// Shared scale-set error taxonomy used by the listener, client, and forge
/// adapter so the engine can render actionable messages without parsing HTTP
/// bodies or private implementation details.
public enum ScaleSetError: LocalizedError, Sendable {
    case noSession(reason: String)
    case sessionRefreshFailed(reason: String)
    case adminTokenFailure(reason: String)
    case scaleSetIdFailure(reason: String)
    case statisticsUnavailable(reason: String)
    case messageServiceFailure(reason: String)
    case jitConfigFailure(reason: String)
    case registrationFailure(reason: String)

    public var errorDescription: String? {
        switch self {
        case .noSession(let reason):
            return "scale-set session is not active: \(reason)"
        case .sessionRefreshFailed(let reason):
            return "scale-set session refresh failed: \(reason)"
        case .adminTokenFailure(let reason):
            return "scale-set admin token unavailable: \(reason)"
        case .scaleSetIdFailure(let reason):
            return "scale-set id unavailable: \(reason)"
        case .statisticsUnavailable(let reason):
            return "scale-set statistics unavailable: \(reason)"
        case .messageServiceFailure(let reason):
            return "scale-set message service failed: \(reason)"
        case .jitConfigFailure(let reason):
            return "scale-set JIT config generation failed: \(reason)"
        case .registrationFailure(let reason):
            return "scale-set registration failed: \(reason)"
        }
    }
}

// MARK: - Listener actor

/// Owns one GitHub scale-set session and feeds demand back into the engine.
/// This is the replacement for the REST workflow-runs poll for accounts that opt
/// into scale-set mode.
public actor GitHubScaleSetListener {
    private var session: GitHubScaleSetSession?
    /// Id of a session we stopped polling after a failure but never deleted; GitHub still treats it
    /// as active (409 on create) until it is refreshed or expires.
    private var abandonedSessionId: String?
    private var lastMessageId: String?
    private var cachedSnapshot: GitHubScaleSetSnapshot?
    private var pendingActions: [String: GitHubScaleSetJobEvent] = [:]
    private var backOff: Duration = .seconds(1)
    private var messagePollTask: Task<Void, Never>?
    private var statisticsPollTask: Task<Void, Never>?
    private var sessionRetryTask: Task<Void, Never>?
    private var isRunning = false

    private let client: GitHubScaleSetServing
    private let scaleSetIdSupplier: () async throws -> Int
    private let ownerName: String
    private let fallbackRepository: String?
    private let onDemandUpdate: @Sendable () async -> Void
    private let pollInterval: Duration
    private let maxCapacity: Int
    private var cachedScaleSetId: Int?
    private var cachedStatistics: GitHubScaleSetStatistics?
    private var statisticsExpiresAt: Date?
    private var _lastError: ScaleSetError?

    public init(
        client: GitHubScaleSetServing,
        scaleSetIdSupplier: @escaping @Sendable () async throws -> Int,
        ownerName: String,
        fallbackRepository: String? = nil,
        pollInterval: Duration = .seconds(2),
        maxCapacity: Int = 1_000,
        onDemandUpdate: @escaping @Sendable () async -> Void = {}
    ) {
        self.client = client
        self.scaleSetIdSupplier = scaleSetIdSupplier
        self.ownerName = ownerName
        self.fallbackRepository = fallbackRepository
        self.pollInterval = pollInterval
        self.maxCapacity = max(0, maxCapacity)
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
        session = nil
        abandonedSessionId = nil
        cachedSnapshot = nil
        pendingActions = [:]
        cachedScaleSetId = nil
        cachedStatistics = nil
        statisticsExpiresAt = nil
        _lastError = nil
    }

    /// The last error observed during listener maintenance.
    public func reportedError() -> ScaleSetError? { _lastError }

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

    // MARK: - Testing surface

    /// Replace the cached snapshot inputs for testability. This is the seam
    /// the unit tests use so the listener's demand path can be asserted without
    /// standing up a session and poll loop.
    func updateSnapshot(
        statistics: GitHubScaleSetStatistics,
        pendingActions: [String: GitHubScaleSetJobEvent]
    ) {
        self.pendingActions = pendingActions
        let tracked = Array(pendingActions.values)
        var attributedRepos = Set(tracked.map { "\($0.ownerName)/\($0.repositoryName)" })
        if attributedRepos.isEmpty, let fallbackRepository {
            attributedRepos.insert(fallbackRepository)
        }
        cachedSnapshot = GitHubScaleSetSnapshot(
            statistics: statistics,
            trackedJobs: tracked,
            attributedRepos: attributedRepos
        )
    }

    // MARK: - Internal

    private func refreshSession() async {
        do {
            let id = try await currentScaleSetId()
            let createdOrRefreshed = try await client.createOrUpdateSession(
                scaleSetId: id, sessionId: session?.sessionId ?? abandonedSessionId, ownerName: ownerName)
            try Task.checkCancellation()
            guard isRunning else {
                await bestEffort { [self] in
                    try await client.deleteSession(scaleSetId: id, sessionId: createdOrRefreshed.sessionId)
                }
                return
            }
            session = createdOrRefreshed
            abandonedSessionId = nil
            backOff = .seconds(1)
            lastMessageId = nil
            _lastError = nil
        } catch is CancellationError {
            return
        } catch let error as ScaleSetError {
            _lastError = error
            Log.warn("scaleset", "session refresh failed: \(String(describing: error.errorDescription))")
            scheduleBackoff()
        } catch {
            let reason = error.localizedDescription
            let failure = ScaleSetError.sessionRefreshFailed(reason: reason)
            _lastError = failure
            Log.warn("scaleset", "session refresh failed: \(reason)")
            scheduleBackoff()
        }
    }

    private func pollLoop() async {
        while !Task.isCancelled {
            if session == nil {
                do { try await Task.sleep(for: pollInterval) } catch { return }
                continue
            }
            do {
                try await pollOnce()
            } catch is CancellationError {
                return
            } catch let error as URLError where error.code == .timedOut {
                // A long-poll that outlives the client timeout is not a dead session; poll again.
                Log.debug("scaleset", "message poll timed out; polling again")
            } catch {
                let reason = error.localizedDescription
                Log.warn("scaleset", "message poll failed: \(reason)")
                _lastError = error as? ScaleSetError ?? .messageServiceFailure(reason: reason)
                abandonedSessionId = session?.sessionId
                session = nil
                scheduleBackoff()
            }
            do { try await Task.sleep(for: pollInterval) } catch { return }
        }
    }

    private func statisticsPollLoop() async {
        while !Task.isCancelled {
            do {
                try await updateSnapshot()
            } catch is CancellationError {
                return
            } catch {
                let reason = error.localizedDescription
                _lastError = error as? ScaleSetError ?? .statisticsUnavailable(reason: reason)
                Log.warn("scaleset", "statistics poll failed: \(reason)")
            }
            do { try await Task.sleep(for: .seconds(5)) } catch { return }
        }
    }

    private func pollOnce() async throws {
        guard session != nil else { throw ScaleSetError.noSession(reason: "listener is not started") }
        guard let id = cachedScaleSetId else {
            throw ScaleSetError.scaleSetIdFailure(reason: "scale-set id was not cached")
        }
        guard let activeSession = self.session else { throw ScaleSetError.noSession(reason: "listener is not started") }
        let messages: [GitHubScaleSetMessage]
        do {
            messages = try await client.pollMessages(
                session: activeSession, lastMessageId: lastMessageId, maxCapacity: maxCapacity)
        } catch GitHubScaleSetClientError.messageQueueTokenExpired {
            let refreshed = try await client.refreshSession(scaleSetId: id, sessionId: activeSession.sessionId)
            self.session = refreshed
            let retried = try await client.pollMessages(
                session: refreshed, lastMessageId: lastMessageId, maxCapacity: maxCapacity)
            try await process(retried, session: refreshed, scaleSetId: id)
            return
        }
        try await process(messages, session: activeSession, scaleSetId: id)
    }

    private func process(
        _ messages: [GitHubScaleSetMessage], session: GitHubScaleSetSession, scaleSetId: Int
    ) async throws {
        for message in messages {
            try Task.checkCancellation()
            let snapshotBeforeMessage = cachedSnapshot
            for event in message.events {
                try await handleEvent(event)
            }
            if let statistics = message.statistics {
                try acceptStatistics(statistics)
                publishSnapshot(statistics: statistics)
            }
            if snapshotBeforeMessage != cachedSnapshot { await onDemandUpdate() }
            do {
                try await client.ackMessage(session: session, messageId: message.messageId)
            } catch GitHubScaleSetClientError.messageQueueTokenExpired {
                let refreshed = try await client.refreshSession(scaleSetId: scaleSetId, sessionId: session.sessionId)
                self.session = refreshed
                try await client.ackMessage(session: refreshed, messageId: message.messageId)
            }
            lastMessageId = message.messageId
        }
        if messages.isEmpty { try await updateSnapshot() }
    }

    func handleMessage(_ message: GitHubScaleSetMessage, session: GitHubScaleSetSession) async throws {
        let snapshotBeforeMessage = cachedSnapshot
        for event in message.events {
            try await handleEvent(event)
        }
        if let statistics = message.statistics {
            try acceptStatistics(statistics)
            publishSnapshot(statistics: statistics)
        }
        if snapshotBeforeMessage != cachedSnapshot { await onDemandUpdate() }
        try await client.ackMessage(session: session, messageId: message.messageId)
        lastMessageId = message.messageId
    }

    private func handleEvent(_ jobEvent: GitHubScaleSetJobEvent) async throws {
        let previous = pendingActions[jobEvent.runnerRequestId]
        if jobEvent.eventType == .jobCompleted {
            pendingActions[jobEvent.runnerRequestId] = nil
        } else {
            pendingActions[jobEvent.runnerRequestId] = jobEvent
        }
        guard previous != pendingActions[jobEvent.runnerRequestId] else { return }
        if let cachedStatistics {
            publishSnapshot(statistics: cachedStatistics)
        }
    }

    private func acceptStatistics(_ statistics: GitHubScaleSetStatistics) throws {
        guard statistics.totalAssignedJobs >= 0, statistics.activeNodesCount >= 0 else {
            throw ScaleSetError.statisticsUnavailable(reason: "API returned negative statistics")
        }
        cachedStatistics = statistics
        statisticsExpiresAt = Date().addingTimeInterval(5)
        if case .statisticsUnavailable = _lastError { _lastError = nil }
    }

    private func updateSnapshot() async throws {
        let statistics = try await currentStatistics()
        let previousSnapshot = cachedSnapshot
        publishSnapshot(statistics: statistics)
        if cachedSnapshot != previousSnapshot { await onDemandUpdate() }
    }

    private func publishSnapshot(statistics: GitHubScaleSetStatistics) {
        let tracked = Array(pendingActions.values)
        var attributedRepos = Set(tracked.map { "\($0.ownerName)/\($0.repositoryName)" })
        if attributedRepos.isEmpty, let fallbackRepository {
            attributedRepos.insert(fallbackRepository)
        }
        let snapshot = GitHubScaleSetSnapshot(
            statistics: statistics,
            trackedJobs: tracked,
            attributedRepos: attributedRepos
        )
        guard snapshot != cachedSnapshot else { return }
        cachedSnapshot = snapshot
    }

    private func currentStatistics() async throws -> GitHubScaleSetStatistics {
        if let cached = cachedStatistics, statisticsExpiresAt.map({ Date() < $0 }) == true {
            return cached
        }
        if let cachedSnapshot {
            do {
                try Task.checkCancellation()
                let id = try await currentScaleSetId()
                let stats = try await client.scaleSetStatistics(scaleSetId: id)
                try Task.checkCancellation()
                try acceptStatistics(stats)
                return stats
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                _lastError = .statisticsUnavailable(reason: error.localizedDescription)
                Log.warn(
                    "scaleset", "statistics refresh failed; serving last known snapshot: \(error.localizedDescription)")
                return cachedSnapshot.statistics
            }
        }
        do {
            try Task.checkCancellation()
            let id = try await currentScaleSetId()
            let stats = try await client.scaleSetStatistics(scaleSetId: id)
            try Task.checkCancellation()
            guard stats.totalAssignedJobs >= 0, stats.activeNodesCount >= 0 else {
                throw ScaleSetError.statisticsUnavailable(reason: "API returned negative statistics")
            }
            try acceptStatistics(stats)
            return stats
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as ScaleSetError {
            _lastError = error
            Log.warn("scaleset", "statistics read failed: \(String(describing: error.errorDescription))")
            throw error
        } catch {
            let failure = ScaleSetError.statisticsUnavailable(reason: error.localizedDescription)
            _lastError = failure
            Log.warn("scaleset", "statistics read failed: \(error.localizedDescription)")
            throw failure
        }
    }

    /// Latest snapshot the listener has published. Before the first poll pass
    /// this is nil; after that it reflects the last computed demand.
    public func snapshot() -> GitHubScaleSetSnapshot? { cachedSnapshot }

    /// Refresh the cached scale-set id from the supplier. This is read by the
    /// Forge adapter's status paths before the listener has established a
    /// message session.
    public func currentScaleSetId() async throws -> Int {
        if let cached = cachedScaleSetId { return cached }
        do {
            try Task.checkCancellation()
            let id = try await scaleSetIdSupplier()
            cachedScaleSetId = id
            return id
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            cachedScaleSetId = nil
            throw ScaleSetError.scaleSetIdFailure(reason: error.localizedDescription)
        }
    }

    /// Statistics cached by the listener's lightweight poll.
    public func scaleSetStatistics() async throws -> GitHubScaleSetStatistics {
        try await currentStatistics()
    }

    /// Forge-owned JIT config generation via the listener's underlying scale-set
    /// client. Kept on the listener so the Forge adapter does not need privileged
    /// access to the listener's private `client` property.
    public func generateJitConfig(
        scaleSetId: Int, name: String, workFolder: String
    ) async throws -> GitHubScaleSetJitConfig {
        do {
            return try await client.generateJitConfig(
                scaleSetId: scaleSetId, name: name, workFolder: workFolder)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw ScaleSetError.jitConfigFailure(reason: error.localizedDescription)
        }
    }

    private func resolveJobs(from snap: GitHubScaleSetSnapshot) -> [ForgeJob] {
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

    private func synthesizePlaceholderJobs(upTo count: Int, into snap: GitHubScaleSetSnapshot) -> [ForgeJob] {
        let existingRepos = Array(snap.attributedRepos)
        guard !existingRepos.isEmpty else { return [] }
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

    private func scheduleBackoff() {
        guard isRunning, sessionRetryTask == nil else { return }
        backOff = min(backOff * 2, .seconds(30))
        let delay = backOff
        sessionRetryTask = Task { [weak self] in
            do { try await Task.sleep(for: delay) } catch { return }
            guard let self else { return }
            await self.retrySessionAfterBackoff()
        }
    }

    private func retrySessionAfterBackoff() async {
        sessionRetryTask = nil
        guard isRunning, !Task.isCancelled else { return }
        await refreshSession()
    }

    private func bestEffort(_ block: @escaping @Sendable () async throws -> Void) async {
        do { try await block() } catch { Log.warn("scaleset", "best-effort failed: \(error.localizedDescription)") }
    }
}

// MARK: - Event type helper
