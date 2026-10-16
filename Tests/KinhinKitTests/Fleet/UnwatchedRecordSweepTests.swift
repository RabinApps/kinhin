import Synchronization
import XCTest

@testable import KinhinKit
@testable import KinhinTestSupport

/// Records nothing drives (a warm instance has no lifecycle task, so no
/// liveness watch): the engine's own sweep removes the ones whose instance
/// vanished or was stopped, with healing on or off, and journals each removal.
final class UnwatchedRecordSweepTests: XCTestCase {
    private func makeEngine(
        tart: FakeTart, grace: Duration = .zero, healing: KinhinConfig.HealingConfig = .default
    ) -> FleetEngine {
        var config = makeTestConfig()
        config.healing = healing
        return FleetEngine(
            config: config, github: FakeGitHub(), tart: tart, store: makeTestStore(), ssh: FakeSSH(),
            host: testHost,
            dependencies: .init(tokenLoader: { _, _ in "test-token" }, watchdog: Watchdog(unwatchedGrace: grace)))
    }

    private func warmRecord(_ id: String) -> VMRecord {
        var record = VMRecord(id: id, phase: .warm, createdAt: Date().addingTimeInterval(-60))
        record.runtime = RuntimeID.tart.rawValue
        record.updatedAt = Date().addingTimeInterval(-60)
        return record
    }

    func testAWarmInstanceDeletedOutOfBandIsRemovedAndJournaled() async {
        let engine = makeEngine(tart: FakeTart())
        let id = "kinhin-1700000000-aaaa0001"
        engine.store.upsert(warmRecord(id))  // no VM behind it

        await engine.sweepUnwatchedRecords()
        await engine.settleDeletes()

        XCTAssertFalse(engine.store.all.contains { $0.id == id })
        let event = engine.healing.snapshot(advisorName: nil).events.first
        XCTAssertEqual(event?.remediation, Remediation(.recycleInstance, subject: id))
        XCTAssertEqual(event?.outcome, .succeeded)
        XCTAssertEqual(event?.signal.kind, .instanceGone)
    }

    func testAStoppedWarmInstanceIsRemoved() async {
        let tart = FakeTart()
        let id = "kinhin-1700000000-aaaa0002"
        tart.vms[id] = TartVM(name: id, source: "", status: "stopped")
        let engine = makeEngine(tart: tart)
        engine.store.upsert(warmRecord(id))

        await engine.sweepUnwatchedRecords()
        await engine.settleDeletes()

        XCTAssertTrue(tart.deleteCalls.contains(id))
        XCTAssertFalse(engine.store.all.contains { $0.id == id })
        XCTAssertEqual(engine.healing.snapshot(advisorName: nil).events.first?.signal.evidence, .instanceStopped)
    }

    func testItWorksWithHealingOffAndThenJournalsNothing() async {
        let engine = makeEngine(tart: FakeTart(), healing: KinhinConfig.HealingConfig(enabled: false))
        let id = "kinhin-1700000000-aaaa0003"
        engine.store.upsert(warmRecord(id))

        await engine.sweepUnwatchedRecords()
        await engine.settleDeletes()

        XCTAssertFalse(engine.store.all.contains { $0.id == id }, "the engine fixes it whatever healing says")
        XCTAssertTrue(engine.healing.snapshot(advisorName: nil).events.isEmpty)
    }

    func testRunningOrRecentOrUnanswerableInstancesAreLeftAlone() async {
        let tart = FakeTart()
        let running = "kinhin-1700000000-aaaa0004"
        tart.vms[running] = TartVM(name: running, source: "", status: "running")
        let engine = makeEngine(tart: tart)
        engine.store.upsert(warmRecord(running))
        await engine.sweepUnwatchedRecords()
        XCTAssertTrue(engine.store.all.contains { $0.id == running })

        let fresh = makeEngine(tart: FakeTart(), grace: .seconds(300))
        var record = warmRecord("kinhin-1700000000-aaaa0005")
        record.updatedAt = Date()
        fresh.store.upsert(record)
        await fresh.sweepUnwatchedRecords()
        XCTAssertEqual(fresh.store.all.count, 1, "a record younger than the grace is not judged")

        let unlisted = FakeTart()
        unlisted.failList = true
        let blind = makeEngine(tart: unlisted)
        blind.store.upsert(warmRecord("kinhin-1700000000-aaaa0006"))
        await blind.sweepUnwatchedRecords()
        XCTAssertEqual(blind.store.all.count, 1, "a runtime that can't be asked says nothing about its records")
    }

    func testOneListingAnswersForEveryRecord() async {
        let tart = FakeTart()
        let engine = makeEngine(tart: tart)
        for n in 1...4 { engine.store.upsert(warmRecord("kinhin-1700000000-bbbb000\(n)")) }
        let before = tart.listCallCount

        await engine.sweepUnwatchedRecords()

        XCTAssertEqual(tart.listCallCount - before, 1)
    }

    func testTartStatesKeepStoppedApartFromGone() async throws {
        let tart = FakeTart()
        tart.vms["a"] = TartVM(name: "a", source: "", status: "running")
        tart.vms["b"] = TartVM(name: "b", source: "", status: "stopped")
        let runtime = TartRuntime(tart: tart, bootTimeout: { 60 }, tartPath: nil, ssh: FakeSSH())
        let states = try await runtime.states(of: ["a", "b", "c"])
        XCTAssertEqual(states, ["a": .running, "b": .stopped, "c": .gone])
    }

    // MARK: - Forge re-attach single flight

    func testRetryNowJoinsAnAttemptAlreadyRunning() async {
        let engine = makeEngine(tart: FakeTart())
        let runs = Mutex(0)
        let running = Task {
            try? await Task.sleep(for: .milliseconds(100))  // stands in for a slow attach; cancellation is irrelevant
            runs.withLock { $0 += 1 }
        }
        engine.forgeState.withLock { $0.retry.inFlight = running }

        await engine.retryDetachedForgesNow()

        XCTAssertEqual(runs.withLock { $0 }, 1, "it waited for the attempt in flight")
        XCTAssertTrue(engine.forgeState.withLock { $0.retry.inFlight } != nil, "and started no second one")
    }
}
