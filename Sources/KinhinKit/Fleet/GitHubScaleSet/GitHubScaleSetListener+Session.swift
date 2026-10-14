import Foundation

// GitHubScaleSetListener — session establishment, refresh and retry backoff.
extension GitHubScaleSetListener {
    func refreshSession() async {
        do {
            let id = try await currentScaleSetId()
            await reapStaleSession(scaleSetId: id)
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
            sessionStore?.save(
                .init(scaleSetId: id, sessionId: createdOrRefreshed.sessionId, ownerName: ownerName))
            abandonedSessionId = nil
            conflictStreak = 0
            Log.info("scaleset", "session \(createdOrRefreshed.sessionId) established; listening for jobs")
            backOff = .seconds(1)
            lastMessageId = nil
            _lastError = nil
        } catch is CancellationError {
            return
        } catch GitHubError.scaleSetSessionConflict {
            conflictStreak += 1
            let reason =
                conflictStreak >= Self.conflictsBeforeHint
                ? "GitHub still holds a session for this scale set that kinhin has no record of — another kinhin "
                    + "instance (or an earlier run on another machine) is using it. It frees up on its own within a "
                    + "few minutes once that instance stops; nothing needs to be re-created."
                : GitHubError.scaleSetSessionConflict.localizedDescription
            _lastError = .scaleSetSessionRefreshFailed(reason: reason)
            Log.warn("scaleset", "session refresh failed: \(reason)")
            scheduleBackoff()
        } catch let error as GitHubError where error.isScaleSetFailure {
            _lastError = error
            Log.warn("scaleset", "session refresh failed: \(String(describing: error.errorDescription))")
            scheduleBackoff()
        } catch {
            let reason = error.localizedDescription
            let failure = GitHubError.scaleSetSessionRefreshFailed(reason: reason)
            _lastError = failure
            Log.warn("scaleset", "session refresh failed: \(reason)")
            scheduleBackoff()
        }
    }

    /// Deletes the session an earlier run recorded and never deleted, so the
    /// create below succeeds at once instead of waiting out GitHub's lease.
    func reapStaleSession(scaleSetId: Int) async {
        guard !reapedStaleSession else { return }
        reapedStaleSession = true
        guard session == nil, abandonedSessionId == nil, let record = sessionStore?.load(),
            record.scaleSetId == scaleSetId
        else { return }
        await bestEffort { [self] in try await client.deleteSession(scaleSetId: scaleSetId, sessionId: record.sessionId)
        }
        sessionStore?.clear()
        Log.info("scaleset", "removed the session left by an earlier run (\(record.sessionId))")
    }

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
            throw GitHubError.scaleSetIdFailure(reason: error.localizedDescription)
        }
    }

    func scheduleBackoff() {
        guard isRunning, sessionRetryTask == nil else { return }
        backOff = min(backOff * 2, .seconds(30))
        let delay = backOff
        sessionRetryTask = Task { [weak self] in
            do { try await Task.sleep(for: delay) } catch { return }
            guard let self else { return }
            await self.retrySessionAfterBackoff()
        }
    }

    func retrySessionAfterBackoff() async {
        sessionRetryTask = nil
        guard isRunning, !Task.isCancelled else { return }
        await refreshSession()
    }
}
