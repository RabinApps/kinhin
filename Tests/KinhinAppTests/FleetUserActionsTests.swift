import AppKit
import XCTest

@testable import KinhinKit
@testable import kinhin_app

/// The alerting wrappers shared by the menu and the Fleet tab: failures are
/// shown (never silent), a declined confirmation does nothing.
@MainActor
final class FleetUserActionsTests: XCTestCase {
    private var fleet: FleetController!
    private var fake: FakeFleetServing!
    private var alertTitles: [String] = []
    private var answer: NSApplication.ModalResponse = .alertFirstButtonReturn

    override func setUp() async throws {
        try await super.setUp()
        fake = FakeFleetServing()
        fleet = FleetController()
        fleet.service = fake
        fleet.daemonProbe = { false }  // never touch a real daemon socket
        alertTitles = []
        answer = .alertFirstButtonReturn
        AlertKit.runModal = { [unowned self] alert in
            alertTitles.append(alert.messageText)
            return answer
        }
    }

    override func tearDown() async throws {
        AlertKit.runModal = { $0.runModal() }
        fleet = nil
        fake = nil
        try await super.tearDown()
    }

    private func waitUntil(_ message: String, _ condition: () -> Bool) async {
        let deadline = ContinuousClock.now + .seconds(5)
        while !condition() {
            if ContinuousClock.now > deadline { return XCTFail("timed out: \(message)") }
            try? await Task.sleep(for: .milliseconds(10))
        }
    }

    func testStartFailureIsAlertedAndClearsPending() async {
        fake.commandError = RPCError.timeout
        fleet.userStart(openSetup: {})
        XCTAssertEqual(fleet.pendingFleetAction, .start, "pending is set before the task runs")
        await waitUntil("alert") { !alertTitles.isEmpty }
        XCTAssertEqual(alertTitles, ["Couldn't start the fleet"])
        await waitUntil("pending clears") { fleet.pendingFleetAction == nil }
    }

    func testStopFailureIsAlerted() async {
        fake.commandError = RPCError.timeout
        fleet.userStop()
        await waitUntil("alert") { !alertTitles.isEmpty }
        XCTAssertEqual(alertTitles, ["Couldn't stop the fleet"])
    }

    func testPauseAndResumeFailuresNameTheAttempt() async {
        fake.commandError = RPCError.timeout
        fleet.userSetPaused(true)
        await waitUntil("pause alert") { alertTitles.count == 1 }
        fleet.userSetPaused(false)
        await waitUntil("resume alert") { alertTitles.count == 2 }
        XCTAssertEqual(alertTitles, ["Couldn't pause the fleet", "Couldn't resume the fleet"])
    }

    func testDeleteFailureIsAlertedWithTheVMName() async {
        fake.commandError = RPCError.timeout
        fleet.userDeleteVM(id: "kinhin-vm-9")
        await waitUntil("failure alert") { alertTitles.contains("Couldn't delete kinhin-vm-9") }
        XCTAssertEqual(alertTitles.first, "Delete kinhin-vm-9?", "the confirmation comes first")
    }

    func testDeclinedDeleteConfirmationDeletesNothingAndStaysQuiet() async {
        answer = .alertSecondButtonReturn
        fleet.userDeleteVM(id: "kinhin-vm-9")
        try? await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(alertTitles, ["Delete kinhin-vm-9?"])
        XCTAssertFalse(fake.calls.contains("deleteVM(kinhin-vm-9)"))
    }

    func testStartWithoutABackendOpensSetupWithoutAnAlert() {
        fleet.service = nil
        var openedSetup = 0
        fleet.userStart(openSetup: { openedSetup += 1 })
        XCTAssertEqual(openedSetup, 1)
        XCTAssertNil(fleet.pendingFleetAction)
        XCTAssertTrue(alertTitles.isEmpty)
    }

    func testStopWithoutABackendAlertsNotSetUp() async {
        fleet.service = nil
        fleet.userStop()
        await waitUntil("alert") { !alertTitles.isEmpty }
        XCTAssertEqual(alertTitles, ["Couldn't stop the fleet"])
    }
}
