import AppKit
import XCTest

@testable import KinhinKit
@testable import kinhin_app

/// Approve and Dismiss from the Diagnostics sheet: they reach the backend,
/// refresh the status so the sheet follows, and a failure is alerted, never
/// silent.
@MainActor
final class HealingUserActionsTests: XCTestCase {
    private var fleet: FleetController!
    private var fake: FakeFleetServing!
    private var alertTitles: [String] = []

    override func setUp() async throws {
        try await super.setUp()
        fake = FakeFleetServing()
        fake.status.healing = HealingSnapshot(
            enabled: true, automatic: true, advisor: nil,
            events: [
                event("h-00000002", .surfaced, fix: Remediation(.replaceToken, subject: "work")),
                event("h-00000001", .pending, fix: Remediation(.pruneImages)),
            ])
        fleet = FleetController()
        fleet.service = fake
        fleet.environment.daemonProbe = { false }  // never touch a real daemon socket
        alertTitles = []
        AlertKit.runModal = { [unowned self] alert in
            alertTitles.append(alert.messageText)
            return .alertFirstButtonReturn
        }
    }

    override func tearDown() async throws {
        AlertKit.runModal = { $0.runModal() }
        fleet = nil
        fake = nil
        try await super.tearDown()
    }

    private func event(_ id: String, _ outcome: HealingEvent.Outcome, fix: Remediation?) -> HealingEvent {
        HealingEvent(
            id: id, signal: HealingSignal(kind: .diskPressure, detail: "disk full"), remediation: fix,
            source: .playbook, outcome: outcome, detail: "detail of \(id)")
    }

    private func outcome(_ id: String) -> HealingEvent.Outcome? {
        fleet.status?.healing?.events.first { $0.id == id }?.outcome
    }

    func testApprovingReachesTheBackendAndRefreshesTheStatus() async {
        await fleet.userApproveHealing(id: "h-00000001").value
        XCTAssertTrue(fake.calls.contains("approveHealing(h-00000001)"))
        XCTAssertEqual(outcome("h-00000001"), .running, "the refresh shows the approved fix running")
        XCTAssertEqual(alertTitles, [])
    }

    func testDismissingReachesTheBackendAndRefreshesTheStatus() async {
        await fleet.userDismissHealing(id: "h-00000002").value
        XCTAssertTrue(fake.calls.contains("dismissHealing(h-00000002)"))
        XCTAssertEqual(outcome("h-00000002"), .dismissed)
        XCTAssertEqual(alertTitles, [])
    }

    func testAFailedApprovalIsAlertedWithTheFixID() async {
        fake.commandError = RPCError.timeout
        await fleet.userApproveHealing(id: "h-00000001").value
        XCTAssertEqual(alertTitles, ["Couldn't approve fix h-00000001"])
    }

    func testARefusedDismissalIsAlertedAndStillRefreshes() async {
        // Already closed by the time the click lands: the engine refuses it.
        await fleet.userDismissHealing(id: "h-00000002").value
        await fleet.userDismissHealing(id: "h-00000002").value
        XCTAssertEqual(alertTitles, ["Couldn't dismiss h-00000002"])
        XCTAssertEqual(outcome("h-00000002"), .dismissed, "the refresh after a failure shows the real state")
    }

    func testWithNoFleetTheActionIsAlerted() async {
        fleet.service = nil
        await fleet.userApproveHealing(id: "h-00000001").value
        XCTAssertEqual(alertTitles, ["Couldn't approve fix h-00000001"])
    }

    // MARK: - Through the Diagnostics model

    func testTheDiagnosticsModelActsThroughTheFleetAndMarksTheEventBusyMeanwhile() async {
        await fleet.refresh()
        let model = DiagnosticsModel()
        model.fleet = fleet
        XCTAssertEqual(model.healing?.pending.map(\.id), ["h-00000001"])

        model.approveHealing(id: "h-00000001")
        XCTAssertEqual(model.busyHealingIDs, ["h-00000001"], "busy from the click, before the backend answers")
        model.approveHealing(id: "h-00000001")  // a double click while busy does nothing more
        let deadline = ContinuousClock.now + .seconds(5)
        while !model.busyHealingIDs.isEmpty, ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(model.busyHealingIDs, [])
        XCTAssertEqual(fake.calls.filter { $0.hasPrefix("approveHealing") }.count, 1)
        XCTAssertEqual(model.healing?.pending, [], "the sheet follows the refreshed status")
        XCTAssertEqual(model.healing?.running.map(\.id), ["h-00000001"])
    }

    func testWithoutAFleetTheModelShowsNoHealingSectionAndIgnoresClicks() {
        let model = DiagnosticsModel()
        XCTAssertNil(model.healing)
        model.dismissHealing(id: "h-00000002")
        XCTAssertEqual(model.busyHealingIDs, [])
    }
}
