import Foundation
import Synchronization

/// Watches the fleet's problems and fixes what it safely can.
///
/// Every pass it asks for the current signals and, for each problem that has
/// persisted long enough, tries the playbook's fixes in order under a
/// `HealingBudget`. Automatic-tier fixes run; approval-tier fixes wait in the
/// journal for `approve`; manual ones are surfaced with what to do. A problem
/// with no rule, or whose fixes are spent, goes once to the advisor (when one
/// is available), which may only pick from the playbook's candidates for it;
/// otherwise it is surfaced. A problem that goes away closes its open events.
/// Fixes the engine makes itself (`note`) are journaled too.
///
/// The agent never holds the fleet: it runs in its own loop task, so a slow
/// advisor or a long repair never delays a reconcile pass. Approved fixes run
/// in tracked tasks that `stopLoop` cancels; once stopped, the agent writes
/// nothing more to the journal file (a replacement engine owns it).
///
/// ## Locks
///
/// `state` is a leaf lock, never held across an `await`. `writeLock`
/// serializes journal writes and is taken before `state` (to copy the journal
/// it writes), never the other way round.
final class HealingAgent: Sendable {
    /// Cadences. Production defaults; tests and the e2e suite shorten them.
    struct Timings: Sendable, Equatable {
        /// Pause between passes.
        var interval: Duration = .seconds(30)
        /// Minimum spacing of two tries of one fix for one problem.
        var cooldown: TimeInterval = 120
        /// Scales `HealingPlaybook.minimumAge` (1 = as written).
        var ageScale: Double = 1
        /// How long the advisor's availability answer is reused.
        var advisorRecheck: TimeInterval = 600
        /// How long a probe (a runtime's health, the setup checks) is reused.
        var probeTTL: TimeInterval = 300

        /// Seconds instead of minutes, for tests and the e2e suite.
        static let fast = Timings(interval: .seconds(2), cooldown: 4, ageScale: 0.05, advisorRecheck: 5, probeTTL: 5)
    }

    struct State: Sendable {
        var budget: HealingBudget
        var journal: HealingJournal
        /// When each live problem was first seen.
        var firstSeen: [String: Date] = [:]
        /// Problems escalated (advisor asked or surfaced) this episode.
        var escalated: Set<String> = []
        /// Problems the user dismissed, until they go away.
        var dismissed: Set<String> = []
        var advisorAvailable: (answer: Bool, at: Date)?
        /// Probe results by probe key, reused for `probeTTL`.
        var probes: [String: (value: [HealingSignal], at: Date)] = [:]
        /// Health probe answers by runtime, reused for `probeTTL`.
        var evidence: [String: (value: HealingSignal.Evidence?, at: Date)] = [:]
        var loop: Task<Void, Never>?
        /// Approved fixes still running, by event id.
        var fixes: [String: Task<Void, Never>] = [:]
        /// Set by `stopLoop`: the journal file is no longer this agent's.
        var stopped = false
    }

    let policy: KinhinConfig.HealingConfig
    let timings: Timings
    let advisor: any HealingAdvisor
    let journalURL: URL?
    let state: Mutex<State>
    let writeLock = Mutex(())

    init(
        policy: KinhinConfig.HealingConfig, timings: Timings = Timings(),
        advisor: any HealingAdvisor = NoHealingAdvisor(), journalURL: URL?
    ) {
        self.policy = policy
        self.timings = timings
        self.advisor = advisor
        self.journalURL = journalURL
        let journal = journalURL.map { HealingJournal.load(from: $0) } ?? HealingJournal()
        self.state = Mutex(
            State(budget: HealingBudget(maxAttempts: policy.maxAttempts, cooldown: timings.cooldown), journal: journal))
    }

    // MARK: - Loop

    /// Takes the journal over from disk and starts the pass loop (once). The
    /// file is re-read because an engine built while another still ran (a
    /// config rebuild) read it before the other stopped writing. `pass` is the
    /// engine's hook into `pass(actions:now:)`, holding the engine weakly.
    func startLoop(_ pass: @escaping @Sendable () async -> Bool) {
        let reloaded = journalURL.map { HealingJournal.load(from: $0) }
        state.withLock { state in
            state.stopped = false
            if let reloaded { state.journal = reloaded }
            guard policy.enabled, state.loop == nil else { return }
            let interval = timings.interval
            state.loop = Task {
                while !Task.isCancelled {
                    guard await pass() else { return }
                    do {
                        try await Task.sleep(for: interval)
                    } catch {
                        return  // cancelled: the engine stopped
                    }
                }
            }
        }
    }

    /// Stops the loop and every approved fix still running, and hands the
    /// journal file back: nothing is written after this.
    func stopLoop() {
        let tasks = state.withLock { state -> [Task<Void, Never>] in
            defer {
                state.loop = nil
                state.fixes = [:]
                state.stopped = true
            }
            return [state.loop].compactMap { $0 } + Array(state.fixes.values)
        }
        for task in tasks { task.cancel() }
    }

    /// The signals of probe `key`, computed at most once per `probeTTL`.
    func probe(_ key: String, now: Date, _ compute: () async -> [HealingSignal]) async -> [HealingSignal] {
        if let cached = cachedProbe(key), now.timeIntervalSince(cached.at) < timings.probeTTL {
            return cached.value
        }
        let value = await compute()
        state.withLock { $0.probes[key] = (value, now) }
        return value
    }

    /// The last result of probe `key`, however old.
    func cachedProbe(_ key: String) -> (value: [HealingSignal], at: Date)? {
        state.withLock { $0.probes[key] }
    }

    /// The answer of health probe `key`, computed at most once per `probeTTL`.
    func probeEvidence(
        _ key: String, now: Date, _ compute: () async -> HealingSignal.Evidence?
    ) async -> HealingSignal.Evidence? {
        if let cached = state.withLock({ $0.evidence[key] }), now.timeIntervalSince(cached.at) < timings.probeTTL {
            return cached.value
        }
        let value = await compute()
        state.withLock { $0.evidence[key] = (value, now) }
        return value
    }

    // MARK: - Pass

    /// One look at the fleet's problems. Cancellation (the engine stopping)
    /// ends the pass where it is.
    func pass(actions: some HealingActions, now: Date = Date()) async {
        guard policy.enabled else {
            await actions.publish(snapshot(advisorName: nil), alert: nil)
            return
        }
        do {
            let signals = await actions.healingSignals(now: now)
            settle(live: signals, now: now)
            let context = actions.healingPlaybookContext
            for signal in signals {
                try Task.checkCancellation()
                try await handle(signal, context: context, actions: actions, now: now)
            }
        } catch {
            return  // only CancellationError is thrown: the engine is stopping
        }
        await publish(actions)
    }

    /// Closes what went away and forgets its episode.
    private func settle(live signals: [HealingSignal], now: Date) {
        let live = Set(signals.map(\.key))
        state.withLock { state in
            for event in state.journal.events where event.isOpen && !live.contains(event.signal.key) {
                // A running fix finishes on its own and records its outcome.
                guard event.outcome != .running else { continue }
                state.journal.update(event.id, now: now) {
                    $0.outcome = .resolved
                    $0.detail = "the problem went away"
                }
            }
            state.firstSeen = state.firstSeen.filter { live.contains($0.key) }
            for signal in signals where state.firstSeen[signal.key] == nil { state.firstSeen[signal.key] = now }
            state.escalated.formIntersection(live)
            state.dismissed.formIntersection(live)
            state.budget.forget(keepingOnly: live)
        }
        persist()
    }

    /// What to do about one problem this pass, if anything.
    private enum Step {
        case wait
        case apply(Remediation)
        case escalate(exhausted: Bool)
    }

    private func handle(
        _ signal: HealingSignal, context: HealingPlaybook.Context, actions: some HealingActions, now: Date
    ) async throws {
        let fixes = HealingPlaybook.remediations(for: signal, context: context)
        let minimumAge = HealingPlaybook.minimumAge(of: signal.kind) * timings.ageScale
        let step = state.withLock { state -> Step in
            guard let first = state.firstSeen[signal.key], now.timeIntervalSince(first) >= minimumAge else {
                return .wait
            }
            guard !state.dismissed.contains(signal.key), state.journal.openEvent(for: signal.key) == nil else {
                return .wait
            }
            // A fix that succeeded while the problem is still here after its
            // cooldown did not help: move on to the next one.
            if let last = state.journal.events.last(where: { $0.signal.key == signal.key }),
                last.outcome == .succeeded, let fix = last.remediation,
                state.budget.cooledDown(signal, fix, now: now)
            {
                state.budget.exhaust(signal, fix)
            }
            guard let fix = fixes.first(where: { !state.budget.exhausted(signal, $0) }) else {
                return .escalate(exhausted: !fixes.isEmpty)
            }
            return state.budget.allows(signal, fix, now: now) ? .apply(fix) : .wait
        }
        switch step {
        case .wait: return
        case .apply(let fix):
            try await apply(fix, for: signal, source: .playbook, explanation: nil, actions: actions, now: now)
        case .escalate(let exhausted):
            try await escalate(
                signal, exhausted: exhausted, fixes: fixes, context: context, actions: actions, now: now)
        }
    }

    /// Runs, queues or surfaces `fix` by its tier.
    func apply(
        _ fix: Remediation, for signal: HealingSignal, source: HealingEvent.Source, explanation: String?,
        actions: some HealingActions, now: Date, forceApproval: Bool = false
    ) async throws {
        let queued = policy.auto == .none || forceApproval
        let tier: Remediation.Tier = fix.tier == .automatic && queued ? .approval : fix.tier
        switch tier {
        case .automatic:
            let event = HealingEvent(
                signal: signal, remediation: fix, source: source, outcome: .running, detail: fix.summary,
                explanation: explanation, at: now)
            state.withLock { state in
                state.budget.record(signal, fix, now: now)
                state.journal.append(event)
            }
            Log.info("healing", "\(fix.summary) — \(signal.detail)")
            try await run(event.id, fix, actions: actions)
        case .approval:
            record(
                HealingEvent(
                    signal: signal, remediation: fix, source: source, outcome: .pending,
                    detail: "\(fix.summary) needs approval: \(signal.detail)", explanation: explanation, at: now))
            Log.info("healing", "\(fix.summary) waits for approval — \(signal.detail)")
        case .manual:
            record(
                HealingEvent(
                    signal: signal, remediation: fix, source: source, outcome: .surfaced,
                    detail: Self.instructions(for: fix, signal: signal), explanation: explanation, at: now))
        }
    }

    /// Carries out an automatic or approved fix and records the outcome. A
    /// cancelled fix is recorded as interrupted and the cancellation rethrown.
    func run(_ id: String, _ fix: Remediation, actions: some HealingActions) async throws {
        do {
            let detail = try await actions.perform(fix)
            Log.info("healing", "\(fix.summary): \(detail)")
            finish(id, outcome: .succeeded, detail: detail)
        } catch is CancellationError {
            finish(id, outcome: .failed, detail: "interrupted (the engine stopped)")
            throw CancellationError()
        } catch {
            let message = (error as? LocalizedError)?.errorDescription ?? "\(error)"
            Log.warn("healing", "\(fix.summary) failed: \(message)")
            finish(id, outcome: .failed, detail: message)
        }
    }

    func finish(_ id: String, outcome: HealingEvent.Outcome, detail: String) {
        state.withLock { state in
            _ = state.journal.update(id) {
                $0.outcome = outcome
                $0.detail = detail
            }
        }
        persist()
    }

    func record(_ event: HealingEvent) {
        state.withLock { $0.journal.append(event) }
        persist()
    }

    /// Writes the journal, unless this agent was stopped (the file then
    /// belongs to the engine that replaced it).
    func persist() {
        guard let journalURL else { return }
        writeLock.withLock { _ in
            let (journal, stopped) = state.withLock { ($0.journal, $0.stopped) }
            guard !stopped else { return }
            journal.save(to: journalURL)
        }
    }
}
