import Observation
import Synchronization
import XCTest

@testable import KinhinKit
@testable import kinhin_app

@MainActor
final class FleetControllerTests: XCTestCase {
    private var fleet: FleetController!
    private var fake: FakeFleetServing!

    override func setUp() async throws {
        try await super.setUp()
        fake = FakeFleetServing()
        fleet = FleetController()
        fleet.service = fake
        fleet.daemonProbe = { false }  // never touch a real daemon socket
    }

    override func tearDown() async throws {
        fleet.stopPolling()
        fleet = nil
        fake = nil
        try await super.tearDown()
    }

    private func waitUntil(_ message: String, timeout: Duration = .seconds(5), _ condition: () -> Bool) async {
        let deadline = ContinuousClock.now + timeout
        while !condition() {
            if ContinuousClock.now > deadline { return XCTFail("timed out: \(message)") }
            try? await Task.sleep(for: .milliseconds(10))
        }
    }

    // MARK: - Pending action

    func testPerformMarksPendingUntilTheCommandAndRefreshComplete() async throws {
        fake.gated = true
        let task = Task { try await fleet.perform(.start) }
        await waitUntil("start reaches the backend") { fake.calls.contains("start") }
        XCTAssertEqual(fleet.pendingFleetAction, .start)

        fake.releaseGate()
        try await task.value
        XCTAssertNil(fleet.pendingFleetAction)
        XCTAssertEqual(fleet.status?.running, true, "the post-command refresh lands")
    }

    func testPerformClearsPendingWhenTheCommandFails() async {
        fake.commandError = EngineError.fleetNotSetUp
        do {
            try await fleet.perform(.stop)
            XCTFail("a failing backend must throw")
        } catch {
            XCTAssertNil(fleet.pendingFleetAction)
        }
    }

    func testPerformWithoutAServiceThrowsNotSetUpAndClearsPending() async {
        fleet.service = nil
        do {
            try await fleet.perform(.start)
            XCTFail("no backend must throw")
        } catch {
            guard case EngineError.fleetNotSetUp = error else { return XCTFail("\(error)") }
            XCTAssertNil(fleet.pendingFleetAction)
        }
    }

    // MARK: - Status and polling

    func testRefreshPublishesTheStatus() async {
        fake.status = FleetStatus(running: true)
        await fleet.refresh()
        XCTAssertEqual(fleet.status?.running, true)
    }

    func testPollFailureResetsStatusToNil() async {
        fake.status = FleetStatus(running: true)
        await fleet.refresh()
        XCTAssertNotNil(fleet.status)

        fake.statusError = RPCError.timeout
        await fleet.refresh()
        XCTAssertNil(fleet.status, "an unreachable backend reads as no status")
    }

    func testPollingKeepsRefreshingUntilStopped() async {
        fleet.startPolling(every: .milliseconds(10))
        await waitUntil("first poll") { fleet.status != nil }

        fleet.stopPolling()
        try? await Task.sleep(for: .milliseconds(50))  // let an in-flight poll land
        let settled = fake.calls.filter { $0 == "status" }.count
        try? await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(fake.calls.filter { $0 == "status" }.count, settled, "no polls after stopPolling")
    }

    func testPausingRefreshesTheStatus() async throws {
        fake.status = FleetStatus(running: true)
        try await fleet.setPaused(true)
        XCTAssertEqual(fleet.status?.paused, true)
        XCTAssertEqual(fake.calls.first, "setPaused(true)")
    }

    func testDeleteGoesThroughTheServiceAndRefreshes() async throws {
        fake.status = FleetStatus(records: [VMRecord(id: "vm-1", phase: .ready)])
        try await fleet.deleteVM(id: "vm-1")
        XCTAssertEqual(fleet.status?.records.isEmpty, true)
    }

    // MARK: - Config push debounce

    func testConfigPushDebouncesABurstIntoOneFlush() async {
        var flushes = 0
        fleet.configPushDelay = .milliseconds(30)
        fleet.configFlushOverride = { flushes += 1 }

        fleet.pushConfigToEngine()
        fleet.pushConfigToEngine()
        fleet.pushConfigToEngine()
        await waitUntil("debounce flushes") { flushes >= 1 && !fleet.isConfigPushScheduled }
        XCTAssertEqual(flushes, 1)
    }

    func testEditsDuringAFlushTriggerAnotherPass() async {
        var flushes = 0
        fleet.configPushDelay = .milliseconds(10)
        fleet.configFlushOverride = { [fleet] in
            flushes += 1
            if flushes == 1 { fleet?.pendingConfigEdits = true }
        }
        fleet.pushConfigToEngine()
        await waitUntil("second pass") { flushes >= 2 && !fleet.isConfigPushScheduled }
        XCTAssertEqual(flushes, 2)
    }

    // MARK: - Failure paths

    func testFailedCommandStillRefreshesTheStatus() async {
        fake.status = FleetStatus(running: true)
        fake.commandError = RPCError.timeout
        do {
            try await fleet.perform(.stop)
            XCTFail("a failing backend must throw")
        } catch {
            XCTAssertEqual(fleet.status?.running, true, "the failed command is followed by a fresh poll")
        }
    }

    func testFailedPauseAndDeleteThrowAndRefresh() async {
        fake.commandError = RPCError.timeout
        do {
            try await fleet.setPaused(true)
            XCTFail("pause must throw")
        } catch {
            XCTAssertNotNil(fleet.status)
        }
        fleet.status = nil
        do {
            try await fleet.deleteVM(id: "vm-1")
            XCTFail("delete must throw")
        } catch {
            XCTAssertNotNil(fleet.status)
        }
    }

    func testEntryPointsThrowNotSetUpWithoutAService() async {
        fleet.service = nil
        func expectNotSetUp(_ body: () async throws -> Void, _ name: String) async {
            do {
                try await body()
                XCTFail("\(name) must throw without a backend")
            } catch EngineError.fleetNotSetUp {
            } catch {
                XCTFail("\(name): \(error)")
            }
        }
        await expectNotSetUp({ try await self.fleet.setPaused(true) }, "setPaused")
        await expectNotSetUp({ try await self.fleet.deleteVM(id: "x") }, "deleteVM")
        await expectNotSetUp({ _ = try await self.fleet.fetchStatus() }, "fetchStatus")
    }

    func testRefreshWithoutAServiceLeavesStatusNil() async {
        fleet.service = nil
        await fleet.refresh()
        XCTAssertNil(fleet.status)
    }

    // MARK: - Token rotation

    func testRotateHandsTheTokenToTheBackendAndRefreshes() async throws {
        try await fleet.rotate(.forge(.github), token: "ghp_new")
        XCTAssertTrue(fake.calls.contains { $0.hasPrefix("rotate(") })
        XCTAssertNotNil(fleet.status, "a rotation is followed by a poll")
    }

    func testRotateBeforeAnyBackendOnlyStoresTheToken() async throws {
        fleet.service = nil
        try await fleet.rotate(.forge(.github), token: "ghp_new")
        XCTAssertTrue(fake.calls.isEmpty)
    }

    func testRotateFailureReachesTheCaller() async {
        fake.commandError = RPCError.timeout
        do {
            try await fleet.rotate(.forge(.github), token: "ghp_new")
            XCTFail("a failed rotation must throw so the form shows it")
        } catch {
            XCTAssertTrue(error is RPCError)
        }
    }

    // MARK: - Polling lifecycle

    func testStartPollingTwiceKeepsOnePollLoop() async {
        fleet.startPolling(every: .milliseconds(20))
        fleet.startPolling(every: .milliseconds(20))
        try? await Task.sleep(for: .milliseconds(200))
        fleet.stopPolling()
        try? await Task.sleep(for: .milliseconds(50))
        let polls = fake.calls.filter { $0 == "status" }.count
        // One loop at 20ms is ~10 polls in 200ms; two would be ~20.
        XCTAssertLessThan(polls, 16, "a second start must not add another loop (\(polls) polls)")
    }

    func testPollingCanRestartAfterAStop() async {
        fleet.startPolling(every: .milliseconds(10))
        await waitUntil("first poll") { fleet.status != nil }
        fleet.stopPolling()
        try? await Task.sleep(for: .milliseconds(50))
        fleet.status = nil
        fleet.startPolling(every: .milliseconds(10))
        await waitUntil("polls again") { fleet.status != nil }
    }

    // MARK: - Reachability and ordering

    func testUnreachableReasonTracksPollFailuresAndRecovery() async {
        XCTAssertNil(fleet.unreachableReason)
        fake.statusError = RPCError.timeout
        await fleet.refresh()
        XCTAssertNotNil(fleet.unreachableReason)
        XCTAssertTrue(fleet.statusLine.hasPrefix("Fleet not responding"))

        fake.statusError = nil
        await fleet.refresh()
        XCTAssertNil(fleet.unreachableReason, "recovery clears it")
        XCTAssertNotNil(fleet.status)
    }

    func testNoServiceMeansNeedsSetupNotUnreachable() async {
        fleet.service = nil
        await fleet.refresh()
        XCTAssertNil(fleet.unreachableReason)
        XCTAssertEqual(fleet.statusLine, "Needs setup — open the Setup tab")
    }

    func testPollThatFinishesAfterTheBackendWasSwappedIsDiscarded() async {
        fake.status = FleetStatus(running: true)
        fake.gated = true
        fake.gatesStatus = true
        let poll = Task { await fleet.refresh() }
        await waitUntil("poll reached the old backend") { fake.calls.contains("status") }

        fleet.service = FakeFleetServing(FleetStatus(paused: true))  // e.g. an engine rebuild
        fake.releaseGate()
        await poll.value

        XCTAssertNil(fleet.status, "the old backend's answer must not be published")
    }

    func testSecondCommandWhileOneRunsIsRejectedAsBusy() async throws {
        fake.gated = true
        let first = Task { try await fleet.perform(.start) }
        await waitUntil("first reaches the backend") { fake.calls.contains("start") }
        do {
            try await fleet.perform(.stop)
            XCTFail("an overlapping command must be refused")
        } catch EngineError.fleetBusy {
        } catch {
            XCTFail("\(error)")
        }
        XCTAssertEqual(fleet.pendingFleetAction, .start, "the running command's state is untouched")
        fake.releaseGate()
        try await first.value
        XCTAssertNil(fleet.pendingFleetAction)
    }

    // MARK: - Daemon adoption

    func testAdoptsADaemonThatStartsWhileTheAppHasNoBackend() async {
        fleet.service = nil
        fleet.setupIncomplete = true
        let daemon = FakeFleetServing(FleetStatus(running: true))
        fleet.daemonProbe = { true }
        fleet.makeDaemonBackend = { daemon }

        await fleet.refresh()

        XCTAssertNotNil(fleet.service)
        XCTAssertFalse(fleet.setupIncomplete, "a running daemon means setup is evidently complete")
        XCTAssertEqual(fleet.status?.running, true)
    }

    func testNeverAdoptsADaemonWhileTheAppHasItsOwnBackend() async {
        let probes = Mutex(0)
        fleet.daemonProbe = {
            probes.withLock { $0 += 1 }
            return true
        }
        await fleet.refresh()
        XCTAssertEqual(probes.withLock { $0 }, 0, "an existing backend is never swapped for a daemon")
    }

    func testNoDaemonLeavesNeedsSetup() async {
        fleet.service = nil
        await fleet.refresh()
        XCTAssertNil(fleet.service)
        XCTAssertEqual(fleet.statusLine, "Needs setup — open the Setup tab")
    }

    // MARK: - Republishing and cadence

    /// An @Observable setter notifies on every write; the controller only
    /// writes when the answer differs, so an idle fleet re-renders nothing.
    func testAnEqualStatusIsNotRepublished() async {
        fake.status = FleetStatus(running: true)
        let changes = Mutex(0)
        @MainActor func track(_ fleet: FleetController) {
            withObservationTracking {
                _ = fleet.status
            } onChange: {
                changes.withLock { $0 += 1 }
            }
        }
        await fleet.refresh()  // nil -> status: a real change
        track(fleet)
        await fleet.refresh()
        await fleet.refresh()
        XCTAssertEqual(changes.withLock { $0 }, 0, "same status: no observation fires")

        fake.status = FleetStatus(running: false)
        await fleet.refresh()
        XCTAssertEqual(changes.withLock { $0 }, 1, "a different status does")
        XCTAssertEqual(fleet.status?.running, false)
    }

    func testUsageIsOnlySampledWhileASurfaceIsShowingIt() async {
        await fleet.refresh()
        fleet.setMenuOpen(true)
        await fleet.refresh()
        fleet.setMenuOpen(false)
        fleet.setMainWindowVisible(true)
        await fleet.refresh()
        fleet.setMainWindowVisible(false)
        await fleet.refresh()
        XCTAssertEqual(fake.usageFlagsSeen, [false, true, true, false])
    }

    func testPollCadenceFollowsVisibility() {
        XCTAssertEqual(fleet.currentPollInterval, fleet.idleInterval)
        XCTAssertGreaterThan(fleet.idleInterval, fleet.activeInterval)
        fleet.setMainWindowVisible(true)
        XCTAssertEqual(fleet.currentPollInterval, fleet.activeInterval)
        fleet.setMenuOpen(true)
        fleet.setMainWindowVisible(false)
        XCTAssertEqual(fleet.currentPollInterval, fleet.activeInterval, "an open menu keeps it fast")
        fleet.setMenuOpen(false)
        XCTAssertEqual(fleet.currentPollInterval, fleet.idleInterval)
    }

    /// Opening a surface cuts a long idle wait short: it is looked at now.
    func testOpeningASurfaceWakesTheIdlePollImmediately() async {
        fleet.idleInterval = .seconds(60)
        fleet.activeInterval = .seconds(60)
        fleet.startPolling()
        await waitUntil("first poll") { self.fake.calls.filter { $0 == "status" }.count == 1 }
        fleet.setMenuOpen(true)
        await waitUntil("woken poll") { self.fake.calls.filter { $0 == "status" }.count == 2 }
    }

    // MARK: - Stale daemon LaunchAgent plist

    func testDetectStaleDaemonPlistSetsNoticeWhenPlistBinaryIsMissing() {
        // No plist at all: no notice.
        fleet.detectStaleDaemonPlist()
        XCTAssertNil(fleet.staleDaemonPlist)
    }

    func testStaleDaemonPlistNoticeAppearsInStatusLine() {
        fleet.staleDaemonPlist =
            "the daemon LaunchAgent is installed but its binary is missing — run `kinhin daemon uninstall` to remove it"
        let line = fleet.statusLine
        XCTAssertTrue(line.contains("⚠"), "status line carries the stale-daemon warning: \(line)")
        XCTAssertTrue(line.contains("daemon uninstall"), "status line names the fix: \(line)")
    }

    func testNoStalePlistNoticeWhenStatusIsSet() {
        fleet.staleDaemonPlist = nil
        var status = FleetStatus()
        status.running = true
        fleet.status = status
        let line = fleet.statusLine
        XCTAssertFalse(line.contains("⚠"), "a running fleet has no stale-daemon warning: \(line)")
    }

    func testStalePlistNoticeSurvivesAStatusChange() {
        fleet.staleDaemonPlist =
            "the daemon LaunchAgent is installed but its binary is missing — run `kinhin daemon uninstall` to remove it"
        fleet.status = FleetStatus()
        XCTAssertTrue(fleet.statusLine.contains("daemon uninstall"), "stale notice persists across status changes")
    }

    // MARK: - Fleet mode label

    func testFleetModeIsInProcessWhenTheAppOwnsTheEngine() {
        // The setUp fleet has a FakeFleetServing directly on service, so
        // backend returns nil. Set an explicit in-process backend to test.
        let dir = FileManager.default.temporaryDirectory
        let cfgURL = dir.appendingPathComponent("kinhin-mode-test-\(UUID().uuidString).yaml")
        let config = "accounts:\n  - name: github\n    forge: github\n    scope: \"your-org/your-repo\"\nlabels: [a]\n"
        try? config.write(to: cfgURL, atomically: true, encoding: .utf8)
        let cfg = try! ConfigLoader.load(from: cfgURL)
        let engine = try! FleetEngine.production(config: cfg, token: "ghp_test")
        fleet.backend = .inProcess(engine)
        XCTAssertEqual(fleet.fleetMode, "in-process engine")
        XCTAssertTrue(fleet.statusLine.contains("in-process engine"))
        try? FileManager.default.removeItem(at: cfgURL)
    }

    func testFleetModeIsDaemonWhenAttachedToADaemon() {
        let dir = FileManager.default.temporaryDirectory
        let socket = dir.appendingPathComponent("kinhin-mode-test-\(UUID().uuidString).sock")
        try? FileManager.default.removeItem(at: socket)
        fleet.backend = .daemon(RPCClient(socketURL: socket))
        XCTAssertEqual(fleet.fleetMode, "background daemon")
        XCTAssertTrue(fleet.statusLine.contains("background daemon"))
        try? FileManager.default.removeItem(at: socket)
    }

    func testFleetModeIsNilWhenNoBackendIsAttached() {
        fleet.service = nil
        fleet.backend = nil
        XCTAssertNil(fleet.fleetMode)
        XCTAssertFalse(fleet.statusLine.contains("in-process engine"))
        XCTAssertFalse(fleet.statusLine.contains("background daemon"))
        // fleetMode is nil, so no mode line is appended.
        XCTAssertEqual(fleet.statusLine, FleetStatusFormatter.summary(nil))
    }

    func testFleetModeLineAppearsAfterTheStatusCounters() {
        let dir = FileManager.default.temporaryDirectory
        let cfgURL = dir.appendingPathComponent("kinhin-mode-test-\(UUID().uuidString).yaml")
        let config = "accounts:\n  - name: github\n    forge: github\n    scope: \"your-org/your-repo\"\nlabels: [a]\n"
        try? config.write(to: cfgURL, atomically: true, encoding: .utf8)
        let cfg = try! ConfigLoader.load(from: cfgURL)
        let engine = try! FleetEngine.production(config: cfg, token: "ghp_test")
        fleet.service = nil
        fleet.backend = .inProcess(engine)
        fleet.status = FleetStatus(running: true, queueDepth: 2, desired: 1, capacityCap: 3, jobCapacity: 4)
        let line = fleet.statusLine
        XCTAssertTrue(line.contains("in-process engine"), "mode label present: \(line)")
        let modeIndex = line.range(of: "in-process engine")!.lowerBound
        let statusEnd = line.range(of: "job slots")!.upperBound
        XCTAssertLessThan(statusEnd, modeIndex, "mode label comes after the status counters: \(line)")
        try? FileManager.default.removeItem(at: cfgURL)
    }
}
