import XCTest

@testable import KinhinKit
@testable import KinhinTestSupport

/// A warm pool behind a GitHub scale-set forge: demand comes from the listener's messages and
/// statistics (running jobs included), not a REST queue depth, and every job's VM is a one-job
/// JIT runner. After a job ends, the next one must claim the topped-up warm VM in the same run.
final class ScaleSetWarmPoolTests: XCTestCase {
    private let scaleSetID = 17

    private func makeEngine(tart: FakeTart, github: FakeGitHub, listener: GitHubScaleSetListener) -> FleetEngine {
        var config = makeTestConfig()
        config.warmPool = 1
        let account = AccountConfig(
            name: "github", forge: .github, scope: "acme/widgets", labels: ["kinhin"],
            scaleSet: .init(name: "kinhin"))
        config.accounts = [account]
        let engine = FleetEngine(
            config: config, github: github, tart: tart, store: makeTestStore(), ssh: FakeSSH(), host: testHost,
            dependencies: .init(tokenLoader: { _, _ in "test-token" }, exitWatchInterval: .milliseconds(20)))
        let forge = GitHubScaleSetForge(account: account, token: "token", client: github, listener: listener)
        engine.forgeState.withLock { $0.byPlatform = ["github": forge] }
        return engine
    }

    private func makeListener(client: ScriptedScaleSetClient) -> GitHubScaleSetListener {
        GitHubScaleSetListener(
            client: client, scaleSetIdSupplier: { [scaleSetID] in scaleSetID }, ownerName: "acme",
            pollInterval: .seconds(99))
    }

    private func event(
        _ kind: GitHubScaleSetJobEventKind, _ requestID: String, job: String, runner: String? = nil
    ) -> GitHubScaleSetJobEvent {
        GitHubScaleSetJobEvent(
            ownerName: "acme", repositoryName: "widgets", jobDisplayName: job, requestLabels: ["kinhin"],
            runnerRequestId: requestID, eventType: kind, runnerName: runner)
    }

    /// Delivers one message through the listener's production path (events, acquire, statistics, ack).
    private func deliver(
        _ listener: GitHubScaleSetListener, id: String, assigned: Int, running: Int,
        _ events: [GitHubScaleSetJobEvent]
    ) async throws {
        let message = GitHubScaleSetMessage(
            messageId: id, statistics: .init(totalAssignedJobs: assigned, activeNodesCount: running), events: events)
        try await listener.process([message], session: ScriptedScaleSetClient.session, scaleSetId: scaleSetID)
    }

    private func phase(_ engine: FleetEngine, _ id: String) async -> VMPhase? {
        await engine.status().records.first { $0.id == id }?.phase
    }

    private func warmIDs(_ engine: FleetEngine) async -> [String] {
        await engine.status().records.filter { $0.phase == .warm }.map(\.id)
    }

    /// Job A runs on the claimed warm VM, the pool tops up a second one, A ends, then job B arrives.
    private func runBackToBackJobs(requestA: String, requestB: String) async throws {
        let tart = FakeTart()
        let github = FakeGitHub()
        let listener = makeListener(client: ScriptedScaleSetClient())
        let engine = makeEngine(tart: tart, github: github, listener: listener)

        // Idle: the pool boots one warm VM.
        try await engine.reconcileOnce()
        try await waitUntil(timeout: 10) { await self.warmIDs(engine).count == 1 }
        let idle = await warmIDs(engine)
        let firstWarm = try XCTUnwrap(idle.first)

        // Job A is offered, acquired and assigned: it claims the warm VM, whose runner then takes it.
        try await deliver(
            listener, id: "1", assigned: 1, running: 0,
            [event(.jobAvailable, requestA, job: "A"), event(.jobAssigned, requestA, job: "A")])
        try await engine.reconcileOnce()
        try await waitUntil(timeout: 10) { await self.phase(engine, firstWarm) == .ready }
        github.register(name: firstWarm, busy: true)
        try await deliver(listener, id: "2", assigned: 1, running: 1, [event(.jobStarted, requestA, job: "A")])
        try await waitUntil(timeout: 10) { await self.phase(engine, firstWarm) == .busy }

        // With A covered, the pool tops up a second warm VM.
        try await engine.reconcileOnce()
        try await waitUntil(timeout: 10) { await self.warmIDs(engine).count == 1 }
        let toppedUp = await warmIDs(engine)
        let secondWarm = try XCTUnwrap(toppedUp.first)
        XCTAssertNotEqual(secondWarm, firstWarm)

        // A finishes: its runner deregisters and the exit watch deletes the VM.
        try await deliver(listener, id: "3", assigned: 0, running: 0, [event(.jobCompleted, requestA, job: "A")])
        github.deregister(name: firstWarm)
        try await waitUntil(timeout: 10) { await self.phase(engine, firstWarm) == nil }

        // Job B arrives. No restart: the next pass must bind the second warm VM to it.
        try await deliver(
            listener, id: "4", assigned: 1, running: 0,
            [event(.jobAvailable, requestB, job: "B"), event(.jobAssigned, requestB, job: "B")])
        let clonesBeforeB = tart.cloneCalls.count
        try await engine.reconcileOnce()
        try await waitUntil(timeout: 10) {
            let phase = await self.phase(engine, secondWarm)
            return phase == .registering || phase == .ready
        }

        let status = await engine.status()
        let claimed = try XCTUnwrap(status.records.first { $0.id == secondWarm })
        XCTAssertEqual(claimed.platform, "github", "job B claims the topped-up warm VM")
        XCTAssertEqual(tart.cloneCalls.count, clonesBeforeB, "job B is served by the warm VM, not a fresh clone")
        await engine.stop()
    }

    func testTheNextJobClaimsTheWarmVMAfterAJobEnds() async throws {
        try await runBackToBackJobs(requestA: "101", requestB: "102")
    }

    /// Production scale-set messages have been seen with `runnerRequestId` 0 on every event, so the
    /// listener's per-request tracking cannot tell job A's events from job B's.
    func testTheNextJobClaimsTheWarmVMWhenRequestIDsAreZero() async throws {
        try await runBackToBackJobs(requestA: "0", requestB: "0")
    }

    /// A short job can start and end between two runner-list reads, so the list never shows the
    /// runner. The listener's `JobCompleted` names it: the VM must go at once, not sit `ready` until
    /// the registration deadline (minutes), where it would cover job B's demand and leave the warm VM idle.
    func testAJobTooShortForTheRunnerListFreesItsVMForTheNextJob() async throws {
        let tart = FakeTart()
        let github = FakeGitHub()
        let listener = makeListener(client: ScriptedScaleSetClient())
        let engine = makeEngine(tart: tart, github: github, listener: listener)

        try await engine.reconcileOnce()
        try await waitUntil(timeout: 10) { await self.warmIDs(engine).count == 1 }
        let idle = await warmIDs(engine)
        let firstWarm = try XCTUnwrap(idle.first)

        try await deliver(
            listener, id: "1", assigned: 1, running: 0,
            [event(.jobAvailable, "101", job: "A"), event(.jobAssigned, "101", job: "A")])
        try await engine.reconcileOnce()
        try await waitUntil(timeout: 10) { await self.phase(engine, firstWarm) == .ready }

        // While A's VM covers it, the pool tops up a second warm VM.
        try await engine.reconcileOnce()
        try await waitUntil(timeout: 10) { await self.warmIDs(engine).count == 1 }
        let toppedUp = await warmIDs(engine)
        let secondWarm = try XCTUnwrap(toppedUp.first)

        // A runs and finishes without its runner ever appearing in the runner list.
        try await deliver(
            listener, id: "2", assigned: 0, running: 0,
            [
                event(.jobStarted, "101", job: "A", runner: firstWarm),
                event(.jobCompleted, "101", job: "A", runner: firstWarm),
            ])
        try await waitUntil(timeout: 5) { await self.phase(engine, firstWarm) == nil }

        // Job B then claims the warm VM.
        try await deliver(
            listener, id: "3", assigned: 1, running: 0,
            [event(.jobAvailable, "102", job: "B"), event(.jobAssigned, "102", job: "B")])
        try await engine.reconcileOnce()
        try await waitUntil(timeout: 10) { await self.phase(engine, secondWarm) != .warm }
        let status = await engine.status()
        XCTAssertEqual(status.records.first { $0.id == secondWarm }?.platform, "github")
        await engine.stop()
    }
}

/// A scale-set client whose session, JIT configs and acquisitions always succeed; demand is driven
/// by the messages a test hands to `GitHubScaleSetListener.process`.
private final class ScriptedScaleSetClient: GitHubScaleSetServing, Sendable {
    static let session = GitHubScaleSetSession(
        sessionId: "s-1", messageQueueUrl: URL(string: "https://example.invalid/msgs")!,
        messageQueueAccessToken: "mq-token")

    func exchangeRegistrationToken(registrationToken: String) async throws -> GitHubScaleSetRegistrationToken {
        GitHubScaleSetRegistrationToken(
            token: "admin-jwt", expiresAt: .now + 3600, actionsUrl: URL(string: "https://example.invalid")!)
    }

    func ensureScaleSet(name: String, labels: [String], runnerGroup: String?) async throws -> GitHubScaleSet {
        GitHubScaleSet(id: 17, name: name, runnerGroupName: runnerGroup ?? "default", labels: labels)
    }

    func patchScaleSet(id: Int, labels: [String]) async throws {}

    func createSession(scaleSetId: Int, ownerName: String) async throws -> GitHubScaleSetSession { Self.session }

    func refreshSession(scaleSetId: Int, sessionId: String) async throws -> GitHubScaleSetSession { Self.session }

    func deleteSession(scaleSetId: Int, sessionId: String) async throws {}

    func pollMessages(session: GitHubScaleSetSession, lastMessageId: String?, maxCapacity: Int) async throws
        -> [GitHubScaleSetMessage]
    { [] }

    func ackMessage(session: GitHubScaleSetSession, messageId: String) async throws {}

    func acquireJobs(session: GitHubScaleSetSession, scaleSetId: Int, requestIds: [Int64]) async throws -> [Int64] {
        requestIds
    }

    func generateJitConfig(scaleSetId: Int, name: String, workFolder: String) async throws -> GitHubScaleSetJitConfig {
        GitHubScaleSetJitConfig(encodedJitConfig: "jit-\(name)")
    }

    func scaleSetStatistics(scaleSetId: Int) async throws -> GitHubScaleSetStatistics {
        GitHubScaleSetStatistics(totalAssignedJobs: 0, activeNodesCount: 0)
    }
}
