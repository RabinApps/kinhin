import XCTest

@testable import KinhinKit
@testable import KinhinTestSupport

/// Instances that die behind the engine's back: the runner watch notices a
/// stopped or vanished instance, and the orphan sweep finds instances with no
/// record.
final class WatchdogTests: XCTestCase {
    private func makeEngine(tart: FakeTart, github: FakeGitHub, grace: Duration = .seconds(600)) -> FleetEngine {
        FleetEngine(
            config: makeTestConfig(), github: github, tart: tart, store: makeTestStore(), ssh: FakeSSH(),
            host: testHost,
            dependencies: .init(
                tokenLoader: { _, _ in "test-token" }, exitWatchInterval: .milliseconds(20),
                watchdog: Watchdog(
                    livenessInterval: .milliseconds(30), livenessMisses: 2, orphanSweepInterval: .zero,
                    orphanGrace: grace)))
    }

    /// One VM spawned, registered and watched, with a job running on it.
    private func busyVM(_ engine: FleetEngine, github: FakeGitHub) async throws -> String {
        github.queueDepth = 1
        try await engine.reconcileOnce()
        try await waitUntil(timeout: 10) { await engine.status().records.first?.phase == .ready }
        let vm = try XCTUnwrap(engine.store.all.first?.id)
        github.register(name: vm, busy: true)
        try await waitUntil(timeout: 10) { engine.store.all.first?.phase == .busy }
        return vm
    }

    // MARK: - Liveness

    func testVanishedInstanceIsCleanedUpInsteadOfWaitingForTheDeadline() async throws {
        let tart = FakeTart()
        let github = FakeGitHub()
        let engine = makeEngine(tart: tart, github: github)
        let vm = try await busyVM(engine, github: github)

        tart.vms[vm] = nil  // deleted out of band

        try await waitUntil(timeout: 10) { !engine.store.all.contains { $0.id == vm } }
        XCTAssertEqual(github.deletedRunnerIDs.count, 1, "its runner registration is swept too")
        await engine.stop()
    }

    func testStoppedInstanceIsCleanedUp() async throws {
        let tart = FakeTart()
        let github = FakeGitHub()
        let engine = makeEngine(tart: tart, github: github)
        let vm = try await busyVM(engine, github: github)

        tart.vms[vm] = TartVM(name: vm, source: "", status: "stopped")

        try await waitUntil(timeout: 10) { !engine.store.all.contains { $0.id == vm } }
        XCTAssertTrue(tart.deleteCalls.contains(vm))
        await engine.stop()
    }

    func testRunningInstanceIsLeftAlone() async throws {
        let tart = FakeTart()
        let github = FakeGitHub()
        let engine = makeEngine(tart: tart, github: github)
        let vm = try await busyVM(engine, github: github)

        try await Task.sleep(for: .milliseconds(400))  // many liveness intervals

        XCTAssertEqual(engine.store.all.first { $0.id == vm }?.phase, .busy)
        await engine.stop()
    }

    func testAnUnanswerableRuntimeDoesNotReadAsGone() async throws {
        let tart = FakeTart()
        let github = FakeGitHub()
        let engine = makeEngine(tart: tart, github: github)
        let vm = try await busyVM(engine, github: github)

        tart.failList = true  // `tart list` cannot answer: that says nothing about the VM
        try await Task.sleep(for: .milliseconds(400))
        tart.failList = false

        XCTAssertEqual(engine.store.all.first { $0.id == vm }?.phase, .busy)
        await engine.stop()
    }

    func testStateOfEachRuntimeKind() async throws {
        let tart = FakeTart()
        tart.vms["up"] = TartVM(name: "up", source: "", status: "running")
        tart.vms["down"] = TartVM(name: "down", source: "", status: "stopped")
        let runtime = TartRuntime(tart: tart, bootTimeout: { 30 })
        let up = try await runtime.state(id: "up")
        let down = try await runtime.state(id: "down")
        let missing = try await runtime.state(id: "missing")
        XCTAssertEqual(up, .running)
        XCTAssertEqual(down, .stopped)
        XCTAssertEqual(missing, .gone)
    }

    // MARK: - Orphans

    func testGeneratedNamesAreTheOnlyOrphanCandidates() {
        XCTAssertTrue(FleetEngine.isGeneratedInstanceName(VMRecord.newName()))
        XCTAssertTrue(FleetEngine.isGeneratedInstanceName("kinhin-1717000000-a1b2"))
        XCTAssertFalse(FleetEngine.isGeneratedInstanceName("kinhin-ci-linux"))
        XCTAssertFalse(FleetEngine.isGeneratedInstanceName("kinhin-prepare-tmp-1717000000"))
        XCTAssertFalse(FleetEngine.isGeneratedInstanceName("orchard-1717000000-a1b2"))
        XCTAssertFalse(FleetEngine.isGeneratedInstanceName("macos-base"))
    }

    func testUnmanagedInstanceIsReportedThenRemovedAfterTheGrace() async throws {
        let tart = FakeTart()
        let orphan = "kinhin-1717000000-a1b2c3d4"
        tart.vms[orphan] = TartVM(name: orphan, source: "", status: "running")
        tart.vms["kinhin-ci-base"] = TartVM(name: "kinhin-ci-base", source: "", status: "stopped")
        tart.vms["my-own-vm"] = TartVM(name: "my-own-vm", source: "", status: "stopped")
        let engine = makeEngine(tart: tart, github: FakeGitHub(), grace: .seconds(600))
        let start = Date()

        await engine.sweepOrphans(now: start)
        var alerts = await engine.status().alerts ?? []
        XCTAssertTrue(alerts.contains { $0.source == "orphans" && $0.message.contains(orphan) })
        XCTAssertTrue(tart.deleteCalls.isEmpty, "inside the grace period it is only surfaced")

        await engine.sweepOrphans(now: start.addingTimeInterval(601))
        XCTAssertEqual(tart.deleteCalls, [orphan], "past the grace it is removed; images and foreign VMs never")
        alerts = await engine.status().alerts ?? []
        XCTAssertFalse(alerts.contains { $0.source == "orphans" })
    }

    func testInstanceWithARecordIsNeverAnOrphan() async throws {
        let tart = FakeTart()
        let name = "kinhin-1717000000-a1b2c3d4"
        tart.vms[name] = TartVM(name: name, source: "", status: "running")
        let engine = makeEngine(tart: tart, github: FakeGitHub(), grace: .zero)
        engine.store.upsert(VMRecord(id: name, phase: .booting))

        await engine.sweepOrphans(now: Date().addingTimeInterval(10_000))

        XCTAssertTrue(tart.deleteCalls.isEmpty)
    }

    func testAnInstanceThatGetsARecordInTimeIsForgotten() async throws {
        let tart = FakeTart()
        let name = "kinhin-1717000000-a1b2c3d4"
        tart.vms[name] = TartVM(name: name, source: "", status: "running")
        let engine = makeEngine(tart: tart, github: FakeGitHub(), grace: .seconds(600))
        let start = Date()
        await engine.sweepOrphans(now: start)
        engine.store.upsert(VMRecord(id: name, phase: .booting))
        await engine.sweepOrphans(now: start.addingTimeInterval(300))
        engine.store.remove(id: name)

        await engine.sweepOrphans(now: start.addingTimeInterval(700))

        XCTAssertTrue(tart.deleteCalls.isEmpty, "the clock restarted when the record disappeared again")
    }

    func testUnlistableRuntimeNeitherDeletesNorForgets() async throws {
        let tart = FakeTart()
        let name = "kinhin-1717000000-a1b2c3d4"
        tart.vms[name] = TartVM(name: name, source: "", status: "running")
        let engine = makeEngine(tart: tart, github: FakeGitHub(), grace: .seconds(600))
        let start = Date()
        await engine.sweepOrphans(now: start)

        tart.failList = true
        await engine.sweepOrphans(now: start.addingTimeInterval(700))
        XCTAssertTrue(tart.deleteCalls.isEmpty, "a failed listing proves nothing")

        tart.failList = false
        await engine.sweepOrphans(now: start.addingTimeInterval(710))
        XCTAssertEqual(tart.deleteCalls, [name], "the first-seen time survived the failed pass")
    }
}
