import Foundation

// GitHubScaleSetListener — scale-set statistics polling and the published demand snapshot.
extension GitHubScaleSetListener {
    func statisticsPollLoop() async {
        while !Task.isCancelled {
            do {
                try await updateSnapshot()
            } catch is CancellationError {
                return
            } catch {
                let reason = error.localizedDescription
                _lastError = .scaleSetFailure(error, or: .scaleSetStatisticsUnavailable(reason: reason))
                Log.warn("scaleset", "statistics poll failed: \(reason)")
            }
            do { try await Task.sleep(for: .seconds(5)) } catch { return }
        }
    }

    func acceptStatistics(_ statistics: GitHubScaleSetStatistics) throws {
        guard statistics.totalAssignedJobs >= 0, statistics.activeNodesCount >= 0 else {
            throw GitHubError.scaleSetStatisticsUnavailable(reason: "API returned negative statistics")
        }
        cachedStatistics = statistics
        statisticsExpiresAt = Date().addingTimeInterval(5)
        if case .scaleSetStatisticsUnavailable = _lastError { _lastError = nil }
    }

    func updateSnapshot() async throws {
        let statistics = try await currentStatistics()
        let previousSnapshot = cachedSnapshot
        publishSnapshot(statistics: statistics)
        if cachedSnapshot != previousSnapshot { await onDemandUpdate() }
    }

    func publishSnapshot(statistics: GitHubScaleSetStatistics) {
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

    func currentStatistics() async throws -> GitHubScaleSetStatistics {
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
                _lastError = .scaleSetStatisticsUnavailable(reason: error.localizedDescription)
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
            try acceptStatistics(stats)
            return stats
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as GitHubError where error.isScaleSetFailure {
            _lastError = error
            Log.warn("scaleset", "statistics read failed: \(String(describing: error.errorDescription))")
            throw error
        } catch {
            let failure = GitHubError.scaleSetStatisticsUnavailable(reason: error.localizedDescription)
            _lastError = failure
            Log.warn("scaleset", "statistics read failed: \(error.localizedDescription)")
            throw failure
        }
    }

    /// Statistics cached by the listener's lightweight poll.
    public func scaleSetStatistics() async throws -> GitHubScaleSetStatistics {
        try await currentStatistics()
    }
}
