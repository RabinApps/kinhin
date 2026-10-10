import XCTest

@testable import KinhinKit
@testable import KinhinTestSupport

/// Runner records on the forge that outlive or never match an instance: a runner listed (even offline) and then
/// gone finished its lifecycle, a listed runner that never comes online times out, and the sweep removes records of
/// ours that no instance record claims. Driven through `FakeGitLab` (per-runner records, `.deregisters`).
final class ForgeRunnerRecordLifecycleTests: XCTestCase {
    private func makeEngine(tart: FakeTart, grace: Duration = .seconds(600)) -> FleetEngine {
        var cfg = makeTestConfig()
        cfg.vmBootTimeout = 0
        return FleetEngine(
            config: cfg, github: FakeGitHub(), tart: tart, store: makeTestStore(), ssh: FakeSSH(),
            host: testHost,
            dependencies: .init(
                tokenLoader: { _, _ in "t" }, exitWatchInterval: .milliseconds(20),
                watchdog: Watchdog(
                    livenessInterval: .seconds(3600), orphanGrace: grace, registrationGrace: .milliseconds(300))))
    }

    private func addInstance(_ id: String, to engine: FleetEngine, tart: FakeTart) {
        var record = VMRecord(id: id, phase: .ready)
        record.runtimeID = .tart
        engine.store.upsert(record)
        tart.vms[id] = TartVM(name: id, source: "base", status: "running")
    }

    private func isGone(_ id: String, engine: FleetEngine) -> Bool {
        !engine.store.all.contains { $0.id == id }
    }

    /// A short job completes between two reads: the runner was listed (offline) but no poll saw it online. That is
    /// a finished runner, not a failed spawn.
    func testListedThenGoneRunnerIsNotCountedAsASpawnFailure() async throws {
        let tart = FakeTart()
        let engine = makeEngine(tart: tart)
        let forge = FakeGitLab()
        let vm = "kinhin-1717000000-a1b2c3d4"
        addInstance(vm, to: engine, tart: tart)
        forge.runnerList = [ForgeRunner(id: "1", name: vm, busy: false, online: false)]
        let task = Task { try await engine.awaitRunnerExit(id: vm, forge: forge) }
        defer { task.cancel() }

        try await Task.sleep(for: .milliseconds(120))
        forge.runnerList = []

        try await waitUntil(timeout: 10) { self.isGone(vm, engine: engine) }
        XCTAssertNil(engine.spawnBackoff.withLock { $0.entries[.tart] }, "a finished runner is not a failed spawn")
    }

    /// The forge made the record but the agent never connected: past the registration deadline the instance goes
    /// and the failure counts, instead of holding it to the six hour deadline.
    func testListedButNeverOnlineRunnerTimesOut() async throws {
        let tart = FakeTart()
        let engine = makeEngine(tart: tart)
        let forge = FakeGitLab()
        let vm = "kinhin-1717000000-a1b2c3d4"
        addInstance(vm, to: engine, tart: tart)
        forge.runnerList = [ForgeRunner(id: "1", name: vm, busy: false, online: false)]
        let task = Task { try await engine.awaitRunnerExit(id: vm, forge: forge) }
        defer { task.cancel() }

        try await waitUntil(timeout: 10) { self.isGone(vm, engine: engine) }
        XCTAssertEqual(engine.spawnBackoff.withLock { $0.entries[.tart]?.failures }, 1)
    }

    // MARK: - Forge-side orphan sweep

    func testOfflineRecordOfOursWithNoInstanceIsRemovedAfterTheGrace() async throws {
        let engine = makeEngine(tart: FakeTart(), grace: .seconds(600))
        let forge = FakeGitLab()
        engine.forgeState.withLock { $0.byPlatform["gitlab"] = forge }
        forge.runnerList = [
            ForgeRunner(id: "1", name: "kinhin-1717000000-a1b2c3d4", busy: false, online: false),
            ForgeRunner(id: "2", name: "someone-elses-runner", busy: false, online: false),
        ]
        let start = Date()

        await engine.sweepOrphanRunnerRecords(now: start)
        XCTAssertTrue(forge.deletedRunnerIDs.isEmpty, "inside the grace period nothing is removed")

        await engine.sweepOrphanRunnerRecords(now: start.addingTimeInterval(601))
        XCTAssertEqual(forge.deletedRunnerIDs, ["1"], "only the generated name, never a foreign runner")
    }

    func testOnlineRecordOrOneWithAnInstanceIsNeverSwept() async throws {
        let engine = makeEngine(tart: FakeTart(), grace: .zero)
        let forge = FakeGitLab()
        engine.forgeState.withLock { $0.byPlatform["gitlab"] = forge }
        forge.runnerList = [
            ForgeRunner(id: "1", name: "kinhin-1717000000-a1b2c3d4", busy: false, online: true),
            ForgeRunner(id: "2", name: "kinhin-1717000001-a1b2c3d4-r2", busy: false, online: false),
        ]
        engine.store.upsert(VMRecord(id: "kinhin-1717000001-a1b2c3d4", phase: .ready))

        await engine.sweepOrphanRunnerRecords(now: Date().addingTimeInterval(10_000))

        XCTAssertTrue(forge.deletedRunnerIDs.isEmpty)
    }

    func testRunnerNameMapsToItsInstance() {
        XCTAssertEqual(FleetEngine.instanceName(ofRunner: "kinhin-1-ab-r3"), "kinhin-1-ab")
        XCTAssertEqual(FleetEngine.instanceName(ofRunner: "kinhin-1-ab"), "kinhin-1-ab")
    }
}
