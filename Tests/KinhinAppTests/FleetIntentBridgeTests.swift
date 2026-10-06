import XCTest

@testable import KinhinKit
@testable import kinhin_app

/// The production bridge the App Intents use, against a real controller.
@MainActor
final class FleetIntentBridgeTests: XCTestCase {
    private var fleet: FleetController!
    private var fake: FakeFleetServing!
    private var bridge: AppFleetIntentBridge!

    override func setUp() async throws {
        try await super.setUp()
        fake = FakeFleetServing()
        fleet = FleetController()
        fleet.service = fake
        bridge = AppFleetIntentBridge(controller: fleet)
    }

    private func expectNotSetUp(_ body: () async throws -> Void, _ name: String) async {
        do {
            try await body()
            XCTFail("\(name) must fail without a controller")
        } catch EngineError.fleetNotSetUp {
        } catch {
            XCTFail("\(name): \(error)")
        }
    }

    func testIntentsFailWithNotSetUpBeforeTheAppInstallsItsController() async {
        let bare = AppFleetIntentBridge()
        await expectNotSetUp({ _ = try await bare.status() }, "status")
        await expectNotSetUp({ try await bare.startFleet() }, "start")
        await expectNotSetUp({ try await bare.stopFleet() }, "stop")
        await expectNotSetUp({ try await bare.setPaused(true) }, "pause")
        await expectNotSetUp({ try await bare.deleteVM(id: "x") }, "delete")
        await expectNotSetUp({ try await bare.setAutoResume(true) }, "auto-resume")
    }

    func testStartAndStopGoThroughTheControllerAndClearPending() async throws {
        try await bridge.startFleet()
        XCTAssertEqual(fake.calls.filter { $0 == "start" }.count, 1)
        XCTAssertNil(fleet.pendingFleetAction)
        XCTAssertEqual(fleet.status?.running, true, "the intent's command refreshes the shared status")
        try await bridge.stopFleet()
        XCTAssertEqual(fleet.status?.running, false)
    }

    func testBackendFailuresReachTheShortcut() async {
        fake.commandError = RPCError.timeout
        do {
            try await bridge.startFleet()
            XCTFail("a failing start must fail the intent")
        } catch {
            XCTAssertTrue(error is RPCError)
        }
        XCTAssertNil(fleet.pendingFleetAction, "pending clears on failure")
    }

    func testPauseDeleteAndStatusUseTheBackend() async throws {
        var record = VMRecord(id: "kinhin-vm-1", phase: .ready)
        record.createdAt = Date()
        fake.status = FleetStatus(running: true, records: [record])
        try await bridge.setPaused(true)
        try await bridge.deleteVM(id: "kinhin-vm-1")
        let status = try await bridge.status()
        XCTAssertTrue(status.paused)
        XCTAssertEqual(fake.calls, ["setPaused(true)", "status", "deleteVM(kinhin-vm-1)", "status", "status"])
    }

    func testAnIntentCommandWhileTheAppIsBusyIsRefusedNotInterleaved() async throws {
        fake.gated = true
        let first = Task { try await bridge.startFleet() }
        let deadline = ContinuousClock.now + .seconds(5)
        while !fake.calls.contains("start"), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        do {
            try await bridge.stopFleet()
            XCTFail("overlapping commands must be refused")
        } catch EngineError.fleetBusy {
        } catch {
            XCTFail("\(error)")
        }
        fake.releaseGate()
        try await first.value
    }
}
