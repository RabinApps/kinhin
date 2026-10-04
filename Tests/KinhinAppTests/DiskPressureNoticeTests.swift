import XCTest

@testable import KinhinKit
@testable import kinhin_app

/// The Fleet tab's dismissible disk-pressure banner: exposed from the status,
/// zeroed by a dismiss, and kept hidden for the session while the same
/// pressure episode persists.
@MainActor final class DiskPressureNoticeTests: XCTestCase {
    private let notice =
        "disk pressure: 15 GB free, a new tart instance needs 50 GB + 10 GB reserve — holding spawns"
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

    private func status(pressure: String?) -> FleetStatus {
        var status = FleetStatus(running: true)
        status.diskPressureNotice = pressure
        return status
    }

    func testFleetModelExposesTheNoticeOnlyWhenSet() {
        let model = FleetModel(controller: fleet)
        XCTAssertNil(model.diskPressureNotice)

        fleet.status = status(pressure: nil)
        XCTAssertNil(model.diskPressureNotice)

        fleet.status = status(pressure: notice)
        XCTAssertEqual(model.diskPressureNotice, notice)
    }

    func testDismissZeroesTheNotice() {
        fleet.status = status(pressure: notice)
        let model = FleetModel(controller: fleet)
        model.dismissDiskPressureNotice()
        XCTAssertNil(model.diskPressureNotice)
    }

    func testDismissHoldsAcrossPollsAndRearmsWhenPressureEases() async {
        fake.status = status(pressure: notice)
        await fleet.refresh()
        XCTAssertEqual(fleet.status?.diskPressureNotice, notice)

        // The engine keeps reporting pressure every pass; a dismissed banner
        // stays hidden instead of reappearing on the next poll.
        fleet.clearDiskPressureNotice()
        await fleet.refresh()
        await fleet.refresh()
        XCTAssertNil(fleet.status?.diskPressureNotice)

        // Pressure eases: the latch re-arms...
        fake.status = status(pressure: nil)
        await fleet.refresh()
        XCTAssertNil(fleet.status?.diskPressureNotice)

        // ...so the next episode shows the banner again.
        fake.status = status(pressure: notice)
        await fleet.refresh()
        XCTAssertEqual(fleet.status?.diskPressureNotice, notice)
    }
}
