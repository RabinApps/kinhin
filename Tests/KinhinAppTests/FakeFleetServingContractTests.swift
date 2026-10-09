import Synchronization
import XCTest

@testable import KinhinKit
@testable import KinhinTestSupport
@testable import kinhin_app

/// Contract for `FakeFleetServing` as a `FleetServing`: the cases
/// `FleetController` and the App Intents branch on must behave like the real
/// `FleetBackend` — the same idle status on a fresh fleet, start/stop and
/// pause flipping the same flags, a deleted record leaving the status on
/// both sides, and a failing backend throwing so the controller clears its
/// pending action and publishes "not responding" for a dead daemon exactly
/// as it does for the fake's scripted error. The real side is a
/// `FleetBackend` over an in-process test engine (fake runtimes, scratch
/// store) and a dead daemon socket; no VMs or daemons are involved. Delete
/// mirrors the engine's id validation (`DeleteVMValidationTests` pins the
/// engine): an unknown or malformed id throws `EngineError.unknownVM` on both
/// sides instead of the fake succeeding silently. Deliberate exclusions
/// (pinned scope): the in-process start that refuses for want of a usable
/// forge — the engine stays stopped with `lastError` instead of throwing,
/// while the fake's `commandError` scripts the daemon's throwing mode, whose
/// surfacing `FleetRequeueSkipTests` pins; the controller's `includeUsage`
/// flag is pinned by the tests asserting `usageFlagsSeen`.
@MainActor
final class FakeFleetServingContractTests: XCTestCase {
    private func makeEngine(store: FleetStore) -> FleetEngine {
        FleetEngine(
            config: makeTestConfig(), github: FakeGitHub(), tart: FakeTart(), store: store,
            ssh: FakeSSH(), host: testHost)
    }

    /// The real backend: an in-process engine whose runtimes are all fakes.
    private func makeReal(store: FleetStore = makeTestStore()) -> FleetBackend {
        .inProcess(makeEngine(store: store))
    }

    /// The real backend in daemon mode, pointed at a socket nothing serves.
    private func deadDaemon() -> FleetBackend {
        .daemon(
            RPCClient(
                socketURL: FileManager.default.temporaryDirectory
                    .appendingPathComponent("kinhin-contract-\(UUID().uuidString).sock")))
    }

    /// The first error `op` throws (nil when it succeeds).
    private func firstError(_ op: () async throws -> Void) async -> Error? {
        do {
            try await op()
            return nil
        } catch {
            return error
        }
    }

    /// The id out of an `EngineError.unknownVM` (nil for any other error).
    private func unknownVMID(_ error: Error?) -> String? {
        guard case EngineError.unknownVM(let id)? = error as? EngineError else { return nil }
        return id
    }

    // MARK: - Status shape

    func testAFreshFleetReadsIdleOnBothSides() async throws {
        let real = try await makeReal().status()
        let fake = try await FakeFleetServing().status()

        XCTAssertEqual(fake.running, real.running, "a fresh fleet is stopped on both sides")
        XCTAssertEqual(fake.running, false)
        XCTAssertEqual(fake.paused, real.paused)
        XCTAssertEqual(fake.records, real.records, "no VMs on a fresh store, none scripted on the fake")
        XCTAssertEqual(fake.records, [])
    }

    // MARK: - Transitions

    func testStartAndStopFlipRunningTheSameWayOnBothSides() async throws {
        let real = makeReal()
        try await real.start()
        let realRunning = try await real.status()
        try await real.stop()
        let realStopped = try await real.status()

        let fake = FakeFleetServing()
        try await fake.start()
        let fakeRunning = try await fake.status()
        try await fake.stop()
        let fakeStopped = try await fake.status()

        XCTAssertEqual(realRunning.running, true, "the engine's start marks the fleet running")
        XCTAssertEqual(fakeRunning.running, realRunning.running, "start means running on both sides")
        XCTAssertEqual(realStopped.running, false, "the engine's stop marks it stopped again")
        XCTAssertEqual(fakeStopped.running, realStopped.running, "stop means stopped on both sides")
        XCTAssertEqual(fakeStopped.paused, realStopped.paused, "neither side pauses itself on stop")
    }

    func testSetPausedFlipsTheFlagTheSameWayOnBothSides() async throws {
        let real = makeReal()
        try await real.setPaused(true)
        let realPaused = try await real.status()
        try await real.setPaused(false)
        let realResumed = try await real.status()

        let fake = FakeFleetServing()
        try await fake.setPaused(true)
        let fakePaused = try await fake.status()
        try await fake.setPaused(false)
        let fakeResumed = try await fake.status()

        XCTAssertEqual(realPaused.paused, true, "the engine's pause marks the status paused")
        XCTAssertEqual(fakePaused.paused, realPaused.paused, "paused means paused on both sides")
        XCTAssertEqual(realResumed.paused, false, "a resume clears it")
        XCTAssertEqual(fakeResumed.paused, realResumed.paused)
    }

    func testDeletingARecordLeavesTheStatusTheSameOnBothSides() async throws {
        var record = VMRecord(id: "kinhin-1", phase: .ready)
        record.createdAt = Date()

        let store = makeTestStore()
        store.upsert(record)
        let real = makeReal(store: store)
        let realBefore = try await real.status()
        XCTAssertTrue(
            realBefore.records.contains { $0.id == "kinhin-1" },
            "the store's records are what the backend's status reports")
        try await real.deleteVM(id: "kinhin-1")
        let realAfter = try await real.status()

        let fake = FakeFleetServing(FleetStatus(records: [record]))
        let fakeBefore = try await fake.status()
        try await fake.deleteVM(id: "kinhin-1")
        let fakeAfter = try await fake.status()

        XCTAssertEqual(fakeBefore.records.map(\.id), realBefore.records.map(\.id))
        XCTAssertEqual(
            fakeAfter.records.map(\.id), realAfter.records.map(\.id),
            "a deleted record leaves the status the same way on both sides")
        XCTAssertEqual(fakeAfter.records, [], "the fake drops the record it was given")
        XCTAssertFalse(realAfter.records.contains { $0.id == "kinhin-1" })
    }

    // MARK: - Failures

    func testDeletingAnUnknownOrMalformedVMThrowsTheSameErrorOnBothSides() async throws {
        // A valid-shaped id neither side has.
        let real = makeReal()
        let fake = FakeFleetServing()
        let realAbsent = await firstError { try await real.deleteVM(id: "kinhin-ghost") }
        let fakeAbsent = await firstError { try await fake.deleteVM(id: "kinhin-ghost") }
        XCTAssertEqual(
            unknownVMID(fakeAbsent), "kinhin-ghost",
            "the fake refuses an id it doesn't have instead of succeeding")
        XCTAssertEqual(
            unknownVMID(realAbsent), "kinhin-ghost",
            "the engine refuses it first — same error, same id")

        // A malformed id (fails `VMRecord.isValidID`) even though a record
        // carries it: the engine never touches it, and neither may the fake.
        var stale = VMRecord(id: "vm-1", phase: .ready)
        stale.createdAt = Date()
        let store = makeTestStore()
        store.upsert(stale)
        let realWithStale = makeReal(store: store)
        let fakeWithStale = FakeFleetServing(FleetStatus(records: [stale]))
        let realMalformed = await firstError { try await realWithStale.deleteVM(id: "vm-1") }
        let fakeMalformed = await firstError { try await fakeWithStale.deleteVM(id: "vm-1") }
        XCTAssertEqual(unknownVMID(fakeMalformed), "vm-1", "malformed ids are refused too")
        XCTAssertEqual(unknownVMID(realMalformed), "vm-1")

        // A rejected delete touches nothing on either side.
        let fakeAfter = try await fakeWithStale.status()
        let realAfter = try await realWithStale.status()
        XCTAssertEqual(
            fakeAfter.records.map(\.id), ["vm-1"],
            "the status keeps the record a rejected delete never dropped")
        XCTAssertEqual(realAfter.records.map(\.id), ["vm-1"])
    }

    func testAFailingBackendThrowsAndTheControllerReadsItTheSameWayOnBothSides() async throws {
        // Real: the daemon socket nothing serves.
        let realController = FleetController()
        realController.service = deadDaemon()
        // Fake: a scripted failure on the same wire type.
        let fakeController = FleetController()
        let fake = FakeFleetServing()
        fake.commandError = RPCError.timeout
        fake.statusError = RPCError.timeout
        fakeController.service = fake

        let realError = await firstError { try await realController.perform(.start) }
        let fakeError = await firstError { try await fakeController.perform(.start) }

        XCTAssertNotNil(realError, "an unreachable daemon must fail the start")
        XCTAssertTrue(realError is RPCError, "the dead socket fails as RPC")
        XCTAssertNotNil(fakeError, "the fake's scripted failure throws to the caller too")
        XCTAssertTrue(
            fakeError is RPCError, "scripted as the same wire error so callers catch either way")
        XCTAssertNil(realController.pendingFleetAction, "pending clears on failure")
        XCTAssertNil(fakeController.pendingFleetAction, "…on both sides")

        await realController.refresh()
        await fakeController.refresh()
        XCTAssertNil(realController.status, "a dead daemon publishes no status")
        XCTAssertNil(fakeController.status, "the fake's statusError must do the same")
        XCTAssertNotNil(realController.unreachableReason, "…and the 'not responding' reason")
        XCTAssertNotNil(
            fakeController.unreachableReason,
            "the fake drives the same not-responding surface the menu shows")
    }

    // MARK: - Benchmarks

    func testAnUnknownBenchmarkRunThrowsTheSameErrorOnBothSides() async {
        let id = "bench-never-\(UUID().uuidString)"
        let real = await firstError { _ = try await self.makeReal().benchStatus(runID: id) }
        let fake = await firstError { _ = try await FakeFleetServing().benchStatus(runID: id) }
        for error in [real, fake] {
            guard case BenchmarkError.unknownRun(let unknown)? = error as? BenchmarkError else {
                return XCTFail("expected unknownRun, got \(String(describing: error))")
            }
            XCTAssertEqual(unknown, id)
        }
    }

    func testCancellingWithNothingRunningAnswersFalseOnBothSides() async throws {
        let real = try await makeReal().benchCancel(runID: "bench-never-\(UUID().uuidString)")
        let fake = try await FakeFleetServing().benchCancel(runID: "bench-never")
        XCTAssertFalse(real)
        XCTAssertFalse(fake)
    }

    func testADeadDaemonRefusesBenchmarkCallsLikeAScriptedFailure() async {
        let dead = deadDaemon()
        let scripted = FakeFleetServing()
        scripted.commandError = RPCError.connectionFailed("daemon.sock")
        let realStart = await firstError { _ = try await dead.benchStart(BenchmarkOptions()) }
        let fakeStart = await firstError { _ = try await scripted.benchStart(BenchmarkOptions()) }
        XCTAssertNotNil(realStart)
        XCTAssertNotNil(fakeStart)
        let realStatus = await firstError { _ = try await dead.benchStatus(runID: nil) }
        XCTAssertNotNil(realStatus)
        let realCancel = await firstError { _ = try await dead.benchCancel(runID: nil) }
        XCTAssertNotNil(realCancel)
    }
}
