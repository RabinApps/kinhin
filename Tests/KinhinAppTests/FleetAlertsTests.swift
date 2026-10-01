import XCTest

@testable import KinhinKit
@testable import kinhin_app

private final class RecordingPoster: FleetAlertPosting {
    var posted: [FleetAlert] = []
    func post(_ alert: FleetAlert) { posted.append(alert) }
}

@MainActor
final class FleetAlertsTests: XCTestCase {
    func testANewErrorPostsOnceAndARepeatDoesNot() {
        let poster = RecordingPoster()
        let alerts = FleetAlerts(poster: poster)
        alerts.observe(status: FleetStatus(lastError: "token rejected"), unreachableReason: nil)
        alerts.observe(status: FleetStatus(lastError: "token rejected"), unreachableReason: nil)
        XCTAssertEqual(poster.posted.map(\.body), ["token rejected"])
        // Cleared, then a different problem: that is news again.
        alerts.observe(status: FleetStatus(), unreachableReason: nil)
        alerts.observe(status: FleetStatus(lastError: "disk pressure"), unreachableReason: nil)
        XCTAssertEqual(poster.posted.map(\.body), ["token rejected", "disk pressure"])
    }

    func testLosingAReachableFleetPostsOnTheEdgeOnly() {
        let poster = RecordingPoster()
        let alerts = FleetAlerts(poster: poster)
        alerts.observe(status: nil, unreachableReason: "timed out")  // never seen it up: silent
        XCTAssertTrue(poster.posted.isEmpty)
        alerts.observe(status: FleetStatus(), unreachableReason: nil)
        alerts.observe(status: nil, unreachableReason: "timed out")
        alerts.observe(status: nil, unreachableReason: "timed out")
        XCTAssertEqual(poster.posted.count, 1)
        XCTAssertEqual(poster.posted.first?.title, "kinhin fleet not responding")
    }

    func testSleepIsPreventedOnlyWhileTheFleetIsRunningAndNotPaused() {
        var began = 0
        var ended = 0
        let preventer = SleepPreventer(
            begin: { _ in
                began += 1
                return NSObject()
            }, end: { _ in ended += 1 })
        preventer.update(fleetRunning: false, paused: false)
        XCTAssertFalse(preventer.isHolding)
        preventer.update(fleetRunning: true, paused: false)
        preventer.update(fleetRunning: true, paused: false)
        XCTAssertTrue(preventer.isHolding)
        XCTAssertEqual(began, 1, "one assertion however many polls")
        preventer.update(fleetRunning: true, paused: true)
        XCTAssertFalse(preventer.isHolding)
        XCTAssertEqual(ended, 1)
    }
}
