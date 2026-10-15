import Synchronization
import XCTest

@testable import KinhinKit
@testable import KinhinTestSupport

/// The agent's decisions against scripted problems: what runs on its own,
/// what waits for approval, what is surfaced, and the advisor guardrails.
final class HealingAgentTests: XCTestCase {
    /// Scripted signals; records every fix and every publish. A spy for this
    /// suite only (the engine's conformance is covered by FleetEngineHealingTests).
    private final class ScriptedActions: HealingActions {
        struct State {
            var signals: [HealingSignal] = []
            var performed: [Remediation] = []
            var failing: Set<Remediation.Kind> = []
            /// Kinds whose fix takes 10 s (until cancelled).
            var slow: Set<Remediation.Kind> = []
            var published: [(HealingSnapshot, String?)] = []
        }
        let state = Mutex(State())
        let context: HealingPlaybook.Context

        init(_ signals: [HealingSignal] = [], cacheAutoPrune: Bool = true) {
            state.withLock { $0.signals = signals }
            context = HealingPlaybook.Context(cacheAutoPrune: cacheAutoPrune)
        }

        var signals: [HealingSignal] {
            get { state.withLock { $0.signals } }
            set { state.withLock { $0.signals = newValue } }
        }
        var performed: [Remediation] { state.withLock { $0.performed } }
        var lastAlert: String? { state.withLock { $0.published.last?.1 } }
        var lastSnapshot: HealingSnapshot? { state.withLock { $0.published.last?.0 } }

        func healingSignals(now: Date) async -> [HealingSignal] { signals }
        func perform(_ fix: Remediation) async throws -> String {
            let (fails, slow) = state.withLock { state -> (Bool, Bool) in
                state.performed.append(fix)
                return (state.failing.contains(fix.kind), state.slow.contains(fix.kind))
            }
            if slow { try await Task.sleep(for: .seconds(10)) }
            if fails { throw EngineError.healingFailed("scripted failure") }
            return "done: \(fix.summary)"
        }
        func healingContext(for signal: HealingSignal) -> String { "context for \(signal.key)" }
        var healingPlaybookContext: HealingPlaybook.Context { context }
        func publish(_ snapshot: HealingSnapshot, alert: String?) async {
            state.withLock { $0.published.append((snapshot, alert)) }
        }
    }

    /// Records what it was asked, answers what it was told to.
    private final class SpyAdvisor: HealingAdvisor {
        let answer: HealingAdvice?
        let available: Bool
        let requests = Mutex<[HealingAdviceRequest]>([])
        init(answer: HealingAdvice?, available: Bool = true) {
            self.answer = answer
            self.available = available
        }
        var name: String { "spy" }
        func isAvailable() async -> Bool { available }
        func advise(_ request: HealingAdviceRequest) async throws -> HealingAdvice? {
            requests.withLock { $0.append(request) }
            return answer
        }
        var asked: Int { requests.withLock { $0.count } }
    }

    private let gone = HealingSignal(kind: .instanceGone, subject: "kinhin-1-a", detail: "gone")
    private let disk = HealingSignal(kind: .diskPressure, detail: "full")
    private let queue = HealingSignal(kind: .queueUnreadable, subject: "gitea", detail: "503")
    private let start = Date(timeIntervalSince1970: 2_000_000)

    private func agent(
        _ policy: KinhinConfig.HealingConfig = .default, advisor: any HealingAdvisor = NoHealingAdvisor(),
        cooldown: TimeInterval = 60
    ) -> HealingAgent {
        HealingAgent(
            policy: policy, timings: HealingAgent.Timings(cooldown: cooldown, ageScale: 0), advisor: advisor,
            journalURL: nil)
    }

    private func events(_ agent: HealingAgent) -> [HealingEvent] { agent.snapshot(advisorName: nil).events }

    // MARK: - Tiers

    func testAnAutomaticFixRunsAndIsJournaled() async {
        let actions = ScriptedActions([gone])
        let agent = agent()
        await agent.pass(actions: actions, now: start)

        XCTAssertEqual(actions.performed, [Remediation(.recycleInstance, subject: "kinhin-1-a")])
        XCTAssertEqual(events(agent).first?.outcome, .succeeded)
        XCTAssertEqual(events(agent).first?.source, .playbook)
        XCTAssertNil(actions.lastAlert)
    }

    func testAutoNoneTurnsEveryFixIntoAnApproval() async throws {
        let actions = ScriptedActions([gone])
        let agent = agent(KinhinConfig.HealingConfig(auto: .none))
        await agent.pass(actions: actions, now: start)

        XCTAssertEqual(actions.performed, [])
        let pending = try XCTUnwrap(events(agent).first)
        XCTAssertEqual(pending.outcome, .pending)
        XCTAssertEqual(actions.lastAlert, "1 fix(es) need approval — run `kinhin heal`")

        try await agent.approve(pending.id, actions: actions)
        try await waitUntil(timeout: 5) { self.events(agent).first?.outcome == .succeeded }
        XCTAssertEqual(actions.performed, [Remediation(.recycleInstance, subject: "kinhin-1-a")])
    }

    func testAnApprovalFixWaitsAndIsNotRaisedTwice() async {
        let actions = ScriptedActions([disk], cacheAutoPrune: false)
        let agent = agent()
        await agent.pass(actions: actions, now: start)
        await agent.pass(actions: actions, now: start.addingTimeInterval(600))

        XCTAssertEqual(actions.performed, [], "pruning images is never automatic")
        XCTAssertEqual(events(agent).map(\.outcome), [.pending])
    }

    func testAManualFixIsSurfacedWithInstructions() async {
        let signal = HealingSignal(kind: .credentials, subject: "work", detail: "token missing")
        let actions = ScriptedActions([signal])
        let agent = agent()
        await agent.pass(actions: actions, now: start)

        XCTAssertEqual(actions.performed, [])
        XCTAssertEqual(events(agent).first?.outcome, .surfaced)
        XCTAssertTrue(events(agent).first?.detail.contains("kinhin auth set --account work") ?? false)
    }

    func testDisabledDoesNothing() async {
        let actions = ScriptedActions([gone])
        let agent = agent(KinhinConfig.HealingConfig(enabled: false))
        await agent.pass(actions: actions, now: start)

        XCTAssertEqual(actions.performed, [])
        XCTAssertTrue(events(agent).isEmpty)
        XCTAssertEqual(actions.lastSnapshot?.enabled, false)
    }

    // MARK: - Budget and escalation

    func testAFailingFixIsRetriedAfterItsCooldownThenEscalated() async {
        let actions = ScriptedActions([gone])
        actions.state.withLock { $0.failing = [.recycleInstance] }
        let agent = agent(KinhinConfig.HealingConfig(maxAttempts: 2))

        await agent.pass(actions: actions, now: start)
        await agent.pass(actions: actions, now: start.addingTimeInterval(10))  // cooling down
        XCTAssertEqual(actions.performed.count, 1)
        await agent.pass(actions: actions, now: start.addingTimeInterval(61))
        XCTAssertEqual(actions.performed.count, 2)
        await agent.pass(actions: actions, now: start.addingTimeInterval(200))
        await agent.pass(actions: actions, now: start.addingTimeInterval(400))

        XCTAssertEqual(actions.performed.count, 2, "the budget is spent")
        let surfaced = events(agent).filter { $0.outcome == .surfaced }
        XCTAssertEqual(surfaced.count, 1, "escalated once per episode")
        XCTAssertTrue(surfaced.first?.detail.hasPrefix("kinhin tried recycle instance kinhin-1-a") ?? false)
    }

    func testAFixThatSucceededButDidNotHelpMovesToTheNextOne() async {
        let actions = ScriptedActions([disk])
        let agent = agent()
        await agent.pass(actions: actions, now: start)
        XCTAssertEqual(actions.performed.map(\.kind), [.pruneToolchainCache])

        await agent.pass(actions: actions, now: start.addingTimeInterval(61))  // disk still full
        XCTAssertEqual(actions.performed.map(\.kind), [.pruneToolchainCache], "no second cache prune")
        XCTAssertEqual(events(agent).first?.remediation?.kind, .pruneImages)
        XCTAssertEqual(events(agent).first?.outcome, .pending)
    }

    func testAProblemThatGoesAwayResolvesItsOpenEventsAndStartsOver() async {
        let actions = ScriptedActions([disk], cacheAutoPrune: false)
        let agent = agent()
        await agent.pass(actions: actions, now: start)
        actions.signals = []
        await agent.pass(actions: actions, now: start.addingTimeInterval(1))

        XCTAssertEqual(events(agent).first?.outcome, .resolved)
        XCTAssertNil(actions.lastAlert)

        actions.signals = [disk]
        await agent.pass(actions: actions, now: start.addingTimeInterval(2))
        XCTAssertEqual(events(agent).first?.outcome, .pending, "a new episode asks again")
    }

    func testSlowProblemsWaitTheirMinimumAge() async {
        let actions = ScriptedActions([queue])
        let agent = HealingAgent(
            policy: .default, timings: HealingAgent.Timings(ageScale: 1),
            advisor: SpyAdvisor(answer: nil), journalURL: nil)
        await agent.pass(actions: actions, now: start)
        XCTAssertTrue(events(agent).isEmpty)
        await agent.pass(
            actions: actions, now: start.addingTimeInterval(HealingPlaybook.minimumAge(of: .queueUnreadable)))
        XCTAssertEqual(events(agent).count, 1)
    }

    // MARK: - Approve and dismiss

    func testDismissLeavesTheProblemAloneUntilItGoesAway() async throws {
        let actions = ScriptedActions([disk], cacheAutoPrune: false)
        let agent = agent()
        await agent.pass(actions: actions, now: start)
        let id = try XCTUnwrap(events(agent).first?.id)

        try await agent.dismiss(id, actions: actions)
        await agent.pass(actions: actions, now: start.addingTimeInterval(600))

        XCTAssertEqual(events(agent).map(\.outcome), [.dismissed])
        XCTAssertNil(actions.lastAlert)
    }

    func testApproveRefusesUnknownAndClosedEvents() async throws {
        let actions = ScriptedActions([gone])
        let agent = agent()
        await agent.pass(actions: actions, now: start)
        let done = try XCTUnwrap(events(agent).first?.id)

        do {
            try await agent.approve("h-00000000", actions: actions)
            XCTFail("expected unknownHealingEvent")
        } catch let error as EngineError {
            XCTAssertEqual(error, .unknownHealingEvent("h-00000000"))
        }
        do {
            try await agent.approve(done, actions: actions)
            XCTFail("expected healingEventNotPending")
        } catch let error as EngineError {
            XCTAssertEqual(error, .healingEventNotPending(id: done, outcome: "succeeded"))
        }
    }

    // MARK: - Advisor guardrails

    func testTheAdvisorPicksAnAllowedFixForAnUnmappedProblem() async {
        let advisor = SpyAdvisor(
            answer: HealingAdvice(remediation: "retry_forge_attach", confident: true, explanation: "forge flapped"))
        let actions = ScriptedActions([queue])
        let agent = agent(advisor: advisor)
        await agent.pass(actions: actions, now: start)

        XCTAssertEqual(actions.performed, [Remediation(.retryForgeAttach, subject: "gitea")])
        XCTAssertEqual(events(agent).first?.source, .advisor)
        XCTAssertEqual(events(agent).first?.explanation, "forge flapped")
        XCTAssertEqual(
            advisor.requests.withLock { $0.first?.candidates }, [Remediation(.retryForgeAttach, subject: "gitea")])
        XCTAssertEqual(advisor.requests.withLock { $0.first?.context }, "context for queue_unreadable:gitea")
    }

    func testAPickOutsideTheAllowlistIsIgnored() async {
        let advisor = SpyAdvisor(
            answer: HealingAdvice(remediation: "run_shell_command", confident: true, explanation: "x"))
        let actions = ScriptedActions([queue])
        let agent = agent(advisor: advisor)
        await agent.pass(actions: actions, now: start)

        XCTAssertEqual(actions.performed, [])
        XCTAssertEqual(events(agent).first?.outcome, .surfaced)
    }

    func testAnAllowedKindForTheWrongProblemIsIgnored() async {
        let advisor = SpyAdvisor(
            answer: HealingAdvice(remediation: "recycle_instance", confident: true, explanation: "x"))
        let actions = ScriptedActions([queue])
        let agent = agent(advisor: advisor)
        await agent.pass(actions: actions, now: start)

        XCTAssertEqual(actions.performed, [], "recycle_instance is not a candidate for a queue problem")
    }

    func testTheAdvisorCannotMakeAnApprovalFixAutomatic() async {
        let spawn = HealingSignal(kind: .spawnFailures, subject: "docker", detail: "exit 1")
        let advisor = SpyAdvisor(
            answer: HealingAdvice(remediation: "repair_runtime", confident: true, explanation: "x"))
        let actions = ScriptedActions([spawn])
        let agent = agent(advisor: advisor)
        await agent.pass(actions: actions, now: start)

        XCTAssertEqual(actions.performed, [])
        XCTAssertEqual(events(agent).first?.outcome, .pending)
        XCTAssertEqual(events(agent).first?.source, .advisor)
    }

    func testADoubtfulPickIsOnlySurfaced() async {
        let advisor = SpyAdvisor(
            answer: HealingAdvice(remediation: "retry_forge_attach", confident: false, explanation: "maybe"))
        let actions = ScriptedActions([queue])
        let agent = agent(advisor: advisor)
        await agent.pass(actions: actions, now: start)

        XCTAssertEqual(actions.performed, [])
        XCTAssertEqual(events(agent).first?.outcome, .surfaced)
        XCTAssertTrue(events(agent).first?.detail.contains("not sure") ?? false)
    }

    func testTheAdvisorIsAskedOncePerEpisode() async {
        let advisor = SpyAdvisor(answer: nil)
        let actions = ScriptedActions([queue])
        let agent = agent(advisor: advisor)
        for second in 0..<5 { await agent.pass(actions: actions, now: start.addingTimeInterval(Double(second) * 100)) }
        XCTAssertEqual(advisor.asked, 1)
    }

    func testAIOffNeverCallsTheAdvisor() async {
        let advisor = SpyAdvisor(
            answer: HealingAdvice(remediation: "retry_forge_attach", confident: true, explanation: ""))
        let actions = ScriptedActions([queue])
        let agent = agent(KinhinConfig.HealingConfig(ai: .off), advisor: advisor)
        await agent.pass(actions: actions, now: start)

        XCTAssertEqual(advisor.asked, 0)
        XCTAssertEqual(events(agent).first?.outcome, .surfaced)
    }

    func testAnUnavailableAdvisorIsNotAsked() async {
        let advisor = SpyAdvisor(answer: nil, available: false)
        let actions = ScriptedActions([queue])
        let agent = agent(advisor: advisor)
        await agent.pass(actions: actions, now: start)
        XCTAssertEqual(advisor.asked, 0)
    }

    // MARK: - Stub advisor (e2e seam)

    func testStubSpecs() {
        XCTAssertEqual(StubHealingAdvisor(spec: "stub:recycle_instance")?.pick, "recycle_instance")
        XCTAssertEqual(StubHealingAdvisor(spec: "stub:invalid")?.pick, "run_shell_command")
        XCTAssertEqual(StubHealingAdvisor(spec: "stub:doubtful:prune_images")?.confident, false)
        XCTAssertNil(StubHealingAdvisor(spec: "apple"))
    }

    func testReleaseCadencesUnlessAskedForFastOnes() {
        XCTAssertEqual(HealingAdvisors.productionTimings(environment: [:]), HealingAgent.Timings())
        #if DEBUG
            XCTAssertEqual(
                HealingAdvisors.productionTimings(environment: ["KINHIN_HEALING_TIMINGS": "fast"]), .fast)
            XCTAssertEqual(
                HealingAdvisors.production(environment: ["KINHIN_HEALING_ADVISOR": "stub:invalid"]).name, "stub")
        #endif
    }

    // MARK: - Review fixes

    func testAnAdvisorFixThatDidNotHelpIsSurfacedOnce() async {
        let advisor = SpyAdvisor(
            answer: HealingAdvice(remediation: "retry_forge_attach", confident: true, explanation: "flapped"))
        let actions = ScriptedActions([queue])
        let agent = agent(advisor: advisor)
        await agent.pass(actions: actions, now: start)
        XCTAssertEqual(events(agent).first?.outcome, .succeeded)

        await agent.pass(actions: actions, now: start.addingTimeInterval(10))  // inside the cooldown
        XCTAssertEqual(events(agent).count, 1)
        await agent.pass(actions: actions, now: start.addingTimeInterval(61))  // the queue is still unreadable
        await agent.pass(actions: actions, now: start.addingTimeInterval(200))

        let surfaced = events(agent).filter { $0.outcome == .surfaced }
        XCTAssertEqual(surfaced.count, 1, "said once, not every pass")
        XCTAssertTrue(surfaced.first?.detail.contains("chose re-attach account gitea, which ran") ?? false)
        XCTAssertEqual(advisor.asked, 1, "the advisor is not asked again in the same episode")
    }

    func testTheAdvisorIsNamedBeforeAnyEscalation() async {
        let actions = ScriptedActions([])
        let agent = agent(advisor: SpyAdvisor(answer: nil))
        await agent.pass(actions: actions, now: start)
        XCTAssertEqual(actions.lastSnapshot?.advisor, "spy")

        let off = HealingAgent(
            policy: KinhinConfig.HealingConfig(ai: .off), advisor: SpyAdvisor(answer: nil), journalURL: nil)
        let offActions = ScriptedActions([])
        await off.pass(actions: offActions, now: start)
        XCTAssertNil(offActions.lastSnapshot?.advisor)
    }

    func testStatusCarriesOpenEntriesAndRecentHistoryOnly() async throws {
        let actions = ScriptedActions([disk], cacheAutoPrune: false)
        let agent = agent()
        for n in 0..<30 {
            agent.note(
                HealingSignal(kind: .instanceGone, subject: "kinhin-\(n)", detail: "gone"),
                fix: Remediation(.recycleInstance, subject: "kinhin-\(n)"), detail: "removed", at: start)
        }
        await agent.pass(actions: actions, now: start)
        let published = try XCTUnwrap(actions.lastSnapshot)
        XCTAssertEqual(published.events.filter { !$0.isOpen }.count, HealingSnapshot.statusHistory)
        XCTAssertEqual(published.pending.count, 1, "open entries always travel")
        XCTAssertEqual(agent.snapshot(advisorName: nil).events.count, 31, "the journal itself keeps everything")
    }

    func testAStoppedAgentWritesNothingAndARestartTakesTheFileOver() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("heal-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }  // best-effort scratch cleanup
        let url = HealingJournal.fileURL(in: directory)

        let old = HealingAgent(policy: .default, journalURL: url)
        old.startLoop { false }
        old.note(gone, fix: Remediation(.recycleInstance, subject: "kinhin-1-a"), detail: "first", at: start)
        let replacement = HealingAgent(policy: .default, journalURL: url)  // built while the old one still runs
        old.note(gone, fix: Remediation(.recycleInstance, subject: "kinhin-1-a"), detail: "second", at: start)
        old.stopLoop()
        old.note(gone, fix: Remediation(.recycleInstance, subject: "kinhin-1-a"), detail: "after stop", at: start)

        XCTAssertEqual(HealingJournal.load(from: url).events.map(\.detail), ["first", "second"], "nothing after stop")
        XCTAssertEqual(replacement.snapshot(advisorName: nil).events.count, 1, "read before the old engine finished")
        replacement.startLoop { false }
        XCTAssertEqual(
            replacement.snapshot(advisorName: nil).events.map(\.detail), ["second", "first"],
            "launch takes over what the old engine last wrote")
        replacement.stopLoop()
    }

    func testApprovingOnAStoppedAgentThrowsAndRunsNothing() async throws {
        let actions = ScriptedActions([gone])
        let agent = agent(KinhinConfig.HealingConfig(auto: .none))
        await agent.pass(actions: actions, now: start)
        let id = try XCTUnwrap(events(agent).first?.id)
        agent.stopLoop()

        do {
            try await agent.approve(id, actions: actions)
            XCTFail("expected healingStopped")
        } catch {
            XCTAssertEqual(error as? EngineError, .healingStopped)
        }
        XCTAssertTrue(actions.performed.isEmpty)
        XCTAssertEqual(events(agent).first?.outcome, .pending)
    }

    func testStopCancelsAnApprovedFixStillRunning() async throws {
        let actions = ScriptedActions([gone])
        actions.state.withLock { $0.slow = [.recycleInstance] }
        let agent = agent(KinhinConfig.HealingConfig(auto: .none))
        await agent.pass(actions: actions, now: start)
        let id = try XCTUnwrap(events(agent).first?.id)

        try await agent.approve(id, actions: actions)
        try await waitUntil(timeout: 5) { !actions.performed.isEmpty }
        agent.stopLoop()

        try await waitUntil(timeout: 5) { self.events(agent).first?.outcome == .failed }
        XCTAssertEqual(events(agent).first?.detail, "interrupted (the engine stopped)")
        XCTAssertTrue(agent.state.withLock { $0.fixes.isEmpty })
    }

    func testPrepareImageNamesTheRightFlag() {
        func text(_ check: String) -> String {
            HealingAgent.instructions(
                for: Remediation(.prepareImage, subject: check),
                signal: HealingSignal(kind: .setupCheck, subject: check, detail: "missing"))
        }
        XCTAssertTrue(text("docker-image").hasSuffix("`kinhin image prepare --docker`"))
        XCTAssertTrue(text("container-image").hasSuffix("`kinhin image prepare --container`"))
        XCTAssertTrue(text("image").hasSuffix("`kinhin image prepare`"))
    }
}
