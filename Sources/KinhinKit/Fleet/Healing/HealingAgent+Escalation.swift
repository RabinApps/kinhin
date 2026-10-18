import Foundation

// MARK: - Escalation (no fix left, or none at all)

extension HealingAgent {
    /// Asks the advisor once per episode, else surfaces the problem. Later
    /// passes of the same episode only check whether an advisor-chosen fix
    /// left the problem in place, and surface that once.
    func escalate(
        _ signal: HealingSignal, exhausted: Bool, fixes: [Remediation], context: HealingPlaybook.Context,
        actions: some HealingActions, now: Date
    ) async throws {
        let first = state.withLock { $0.escalated.insert(signal.key).inserted }
        guard first else {
            surfaceIfAdvisedFixDidNotHelp(signal, now: now)
            return
        }
        let base =
            exhausted
            ? "kinhin tried \(fixes.map(\.summary).joined(separator: ", ")) and the problem remains: \(signal.detail)"
            : signal.detail
        let candidates = state.withLock { state in
            HealingPlaybook.candidates(for: signal, context: context).filter { !state.budget.exhausted(signal, $0) }
        }
        guard !candidates.isEmpty, await advisorIsAvailable(now: now) else {
            record(
                HealingEvent(
                    signal: signal, remediation: nil, source: .playbook, outcome: .surfaced, detail: base, at: now))
            return
        }
        let request = HealingAdviceRequest(
            signal: signal, candidates: candidates, context: actions.healingContext(for: signal))
        let advice: HealingAdvice?
        do {
            advice = try await advisor.advise(request)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            Log.warn("healing", "\(advisor.name) gave no advice: \(error.localizedDescription)")
            advice = nil
        }
        if let advice, let pick = advice.remediation {
            // The guardrail: only a candidate, by kind; its tier is the kind's.
            if let fix = candidates.first(where: { $0.kind.rawValue == pick }) {
                if advice.confident {
                    // A model's own confidence queues the fix for approval; it never runs it alone.
                    try await apply(
                        fix, for: signal, source: .advisor, explanation: advice.explanation, actions: actions,
                        now: now, forceApproval: advice.selfReported)
                } else {
                    record(
                        HealingEvent(
                            signal: signal, remediation: nil, source: .advisor, outcome: .surfaced,
                            detail:
                                "\(base) (\(advice.model ?? advisor.name) suggests: \(fix.summary), but is not sure)",
                            explanation: advice.explanation, at: now))
                }
                return
            }
            Log.warn(
                "healing", "\(advisor.name) picked '\(pick)', which is not an allowed fix for \(signal.key); ignored")
        }
        record(
            HealingEvent(
                signal: signal, remediation: nil, source: .advisor, outcome: .surfaced, detail: base,
                explanation: advice?.explanation, at: now))
    }

    /// The advisor's fix ran (or failed) and, after its cooldown, the problem
    /// is still here: say so once, instead of leaving it silent for the rest
    /// of the episode (the surfaced entry stays open until dismissed or gone).
    func surfaceIfAdvisedFixDidNotHelp(_ signal: HealingSignal, now: Date) {
        let event = state.withLock { state -> HealingEvent? in
            guard let last = state.journal.events.last(where: { $0.signal.key == signal.key }),
                last.source == .advisor, last.outcome == .succeeded || last.outcome == .failed,
                let fix = last.remediation, state.budget.cooledDown(signal, fix, now: now)
            else { return nil }
            let outcome = last.outcome == .succeeded ? "ran" : "failed"
            return HealingEvent(
                signal: signal, remediation: nil, source: .advisor, outcome: .surfaced,
                detail: "\(advisor.name) chose \(fix.summary), which \(outcome), and the problem remains: "
                    + signal.detail,
                at: now)
        }
        if let event { record(event) }
    }

    func advisorIsAvailable(now: Date) async -> Bool {
        guard policy.ai != .off else { return false }
        // A "not ready" answer is rechecked sooner, so a model pulled meanwhile is picked up.
        if let cached = state.withLock({ $0.advisorAvailable }) {
            let ttl =
                cached.answer ? timings.advisorRecheck : min(timings.advisorRecheck, TierReadiness.notReadyRecheck)
            if abs(now.timeIntervalSince(cached.at)) < ttl { return cached.answer }
        }
        let answer = await advisor.isAvailable()
        // A cancelled probe says nothing about the model, so it is not cached.
        guard !Task.isCancelled else { return answer }
        state.withLock { $0.advisorAvailable = (answer, now) }
        return answer
    }
}
