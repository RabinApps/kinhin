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
}
