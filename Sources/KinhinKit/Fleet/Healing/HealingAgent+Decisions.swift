import Foundation

// MARK: - Approve, dismiss, note, publish

extension HealingAgent {
    /// Starts a pending fix in a tracked background task and returns at once
    /// (a repair can take far longer than an RPC may wait). Throws for an
    /// unknown id or one that is not pending.
    func approve(_ id: String, actions: some HealingActions) async throws {
        let fix = try state.withLock { state -> Remediation in
            guard let event = state.journal.event(id) else { throw EngineError.unknownHealingEvent(id) }
            guard event.outcome == .pending, let fix = event.remediation else {
                throw EngineError.healingEventNotPending(id: id, outcome: event.outcome.rawValue)
            }
            state.budget.record(event.signal, fix, now: Date())
            state.journal.update(id) {
                $0.outcome = .running
                $0.detail = "approved: \(fix.summary)"
            }
            return fix
        }
        persist()
        Log.info("healing", "approved \(id): \(fix.summary)")
        await publish(actions)
        state.withLock { state in
            // The task removes itself under this same lock, so it cannot finish before it is stored.
            state.fixes[id] = Task { [weak self] in
                guard let self else { return }
                do {
                    try await self.run(id, fix, actions: actions)
                } catch {
                    // Cancelled by stopLoop: the interruption is recorded; a stopped agent publishes nothing.
                    self.state.withLock { _ = $0.fixes.removeValue(forKey: id) }
                    return
                }
                self.state.withLock { _ = $0.fixes.removeValue(forKey: id) }
                await self.publish(actions)
            }
        }
    }

    /// Closes a pending or surfaced event; its problem is left alone until it goes away.
    func dismiss(_ id: String, actions: some HealingActions) async throws {
        try state.withLock { state in
            guard let event = state.journal.event(id) else { throw EngineError.unknownHealingEvent(id) }
            guard event.outcome == .pending || event.outcome == .surfaced else {
                throw EngineError.healingEventNotPending(id: id, outcome: event.outcome.rawValue)
            }
            state.dismissed.insert(event.signal.key)
            state.journal.update(id) { $0.outcome = .dismissed }
        }
        persist()
        await publish(actions)
    }

    /// Journals a fix the engine carried out itself (the unwatched-record
    /// sweep), so every fix shows in one place. Nothing when healing is off.
    func note(_ signal: HealingSignal, fix: Remediation, detail: String, at now: Date = Date()) {
        guard policy.enabled else { return }
        Log.info("healing", "\(fix.summary) — \(signal.detail)")
        record(
            HealingEvent(
                signal: signal, remediation: fix, source: .playbook, outcome: .succeeded, detail: detail, at: now))
    }

    // MARK: - Snapshot

    func snapshot(advisorName: String?) -> HealingSnapshot {
        let events = state.withLock { $0.journal.newestFirst }
        return HealingSnapshot(
            enabled: policy.enabled, automatic: policy.auto == .safe, advisor: advisorName, events: events)
    }

    /// The full journal with the advisor's current availability (asked when
    /// the cached answer is stale, so it is right before any escalation).
    func currentSnapshot() async -> HealingSnapshot {
        let available = await advisorIsAvailable(now: Date())
        return snapshot(advisorName: available ? advisor.name : nil)
    }

    /// Publishes the status-sized snapshot and the approval alert.
    func publish(_ actions: some HealingActions) async {
        let snapshot = await currentSnapshot()
        let pending = snapshot.pending.count
        let alert = pending == 0 ? nil : "\(pending) fix(es) need approval — run `kinhin heal`"
        await actions.publish(snapshot.forStatus(), alert: alert)
    }

    // MARK: - Manual fixes

    /// What the user should do for a fix only they can carry out.
    static func instructions(for fix: Remediation, signal: HealingSignal) -> String {
        switch fix.kind {
        case .replaceToken:
            let account = fix.subject.map { " --account \($0)" } ?? ""
            return "\(signal.detail) — store a new token with `kinhin auth set\(account)`"
        case .prepareImage:
            // The subject is the setup check that failed; each image has its own prepare flag.
            let command: String
            switch fix.subject {
            case "docker-image": command = "kinhin image prepare --docker"
            case "container-image": command = "kinhin image prepare --container"
            default: command = "kinhin image prepare"
            }
            return "\(signal.detail) — prepare it with `\(command)`"
        case .inspectInstance:
            return "\(signal.detail) — kinhin cannot remove \(fix.subject ?? "the instance"); "
                + "delete it with its runtime (`tart delete`, `docker rm -f` or `container delete`), "
                + "then `kinhin cleanup --vms`"
        case .reviewSetup:
            return "\(signal.detail) — run `kinhin setup status` and use the fix it lists"
        default:
            return "\(signal.detail) — \(fix.summary)"
        }
    }
}
