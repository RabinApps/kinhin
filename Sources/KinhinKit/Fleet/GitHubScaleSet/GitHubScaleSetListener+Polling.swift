import Foundation

// GitHubScaleSetListener — the message long-poll loop and job-event handling.
extension GitHubScaleSetListener {
    func pollLoop() async {
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

    func pollOnce() async throws {
        guard session != nil else { throw ScaleSetError.noSession(reason: "listener is not started") }
        guard let id = cachedScaleSetId else {
            throw ScaleSetError.scaleSetIdFailure(reason: "scale-set id was not cached")
        }
        guard let activeSession = self.session else { throw ScaleSetError.noSession(reason: "listener is not started") }
        let messages: [GitHubScaleSetMessage]
        do {
            messages = try await client.pollMessages(
                session: activeSession, lastMessageId: lastMessageId, maxCapacity: max(0, maxCapacity()))
        } catch GitHubScaleSetClientError.messageQueueTokenExpired {
            let refreshed = try await client.refreshSession(scaleSetId: id, sessionId: activeSession.sessionId)
            self.session = refreshed
            let retried = try await client.pollMessages(
                session: refreshed, lastMessageId: lastMessageId, maxCapacity: max(0, maxCapacity()))
            try await process(retried, session: refreshed, scaleSetId: id)
            return
        }
        try await process(messages, session: activeSession, scaleSetId: id)
    }

    /// Applies one batch of polled messages (events, then statistics), acknowledging each
    /// after its demand was published. Internal so tests drive the production path.
    func process(
        _ messages: [GitHubScaleSetMessage], session: GitHubScaleSetSession, scaleSetId: Int
    ) async throws {
        for message in messages {
            try Task.checkCancellation()
            let snapshotBeforeMessage = cachedSnapshot
            if !message.events.isEmpty {
                let kinds = message.events.map { "\($0.eventType.rawValue)#\($0.runnerRequestId)" }
                Log.info("scaleset", "message \(message.messageId): \(kinds.joined(separator: ", "))")
            }
            for event in message.events {
                try await handleEvent(event)
            }
            // GitHub assigns a JobAvailable job only once a listener acquires it; until then
            // idle runners in this scale set sit listening while the job stays queued. Done
            // before the ack: on failure the message is redelivered and acquiring again is a
            // no-op (actions/scaleset's listener contract).
            try await acquireAvailableJobs(in: message, session: session, scaleSetId: scaleSetId)
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

    func acquireAvailableJobs(
        in message: GitHubScaleSetMessage, session: GitHubScaleSetSession, scaleSetId: Int
    ) async throws {
        let ids = message.events.filter { $0.eventType == .jobAvailable }.compactMap { Int64($0.runnerRequestId) }
        guard !ids.isEmpty else { return }
        let acquired: [Int64]
        do {
            acquired = try await client.acquireJobs(
                session: self.session ?? session, scaleSetId: scaleSetId, requestIds: ids)
        } catch GitHubScaleSetClientError.messageQueueTokenExpired {
            let refreshed = try await client.refreshSession(scaleSetId: scaleSetId, sessionId: session.sessionId)
            self.session = refreshed
            acquired = try await client.acquireJobs(session: refreshed, scaleSetId: scaleSetId, requestIds: ids)
        }
        Log.info("scaleset", "acquired \(acquired.count) of \(ids.count) available job(s)")
    }

    func handleEvent(_ jobEvent: GitHubScaleSetJobEvent) async throws {
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
}
