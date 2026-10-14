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

    // MARK: - Healing

    private func healing(_ events: [(String, HealingEvent.Outcome)]) -> FleetStatus {
        var status = FleetStatus()
        status.healing = HealingSnapshot(
            enabled: true, automatic: true, advisor: nil,
            events: events.map { id, outcome in
                HealingEvent(
                    id: id, signal: HealingSignal(kind: .diskPressure, detail: "disk full"),
                    remediation: Remediation(.pruneToolchainCache), source: .playbook, outcome: outcome,
                    detail: "fixed \(id)")
            })
        return status
    }

    func testAFixThatNewlySucceedsPostsOnceByID() {
        let poster = RecordingPoster()
        let alerts = FleetAlerts(poster: poster)
        alerts.observe(status: healing([("h-1", .running)]), unreachableReason: nil)
        XCTAssertTrue(poster.posted.isEmpty, "a running fix is not news yet")
        alerts.observe(status: healing([("h-1", .succeeded)]), unreachableReason: nil)
        alerts.observe(status: healing([("h-1", .succeeded)]), unreachableReason: nil)
        XCTAssertEqual(poster.posted, [FleetAlert(title: "kinhin fixed a problem", body: "fixed h-1")])
    }

    func testSuccessesAlreadyInTheFirstSnapshotDoNotBurstOnLaunch() {
        let poster = RecordingPoster()
        let alerts = FleetAlerts(poster: poster)
        alerts.observe(status: healing([("h-2", .succeeded), ("h-1", .succeeded)]), unreachableReason: nil)
        XCTAssertTrue(poster.posted.isEmpty)
        // A fix that ran between two polls shows up already succeeded: that is news.
        alerts.observe(
            status: healing([("h-3", .succeeded), ("h-2", .succeeded), ("h-1", .succeeded)]), unreachableReason: nil)
        XCTAssertEqual(poster.posted.map(\.body), ["fixed h-3"])
    }

    func testAStatusWithoutHealingDoesNotCountAsTheFirstSnapshot() {
        let poster = RecordingPoster()
        let alerts = FleetAlerts(poster: poster)
        alerts.observe(status: FleetStatus(), unreachableReason: nil)  // a daemon predating healing
        alerts.observe(status: healing([("h-1", .succeeded)]), unreachableReason: nil)
        XCTAssertTrue(poster.posted.isEmpty, "the first healing snapshot is still history")
    }

    func testAnOutageDoesNotReplayKnownSuccesses() {
        let poster = RecordingPoster()
        let alerts = FleetAlerts(poster: poster)
        alerts.observe(status: healing([("h-1", .running)]), unreachableReason: nil)
        alerts.observe(status: healing([("h-1", .succeeded)]), unreachableReason: nil)
        alerts.observe(status: nil, unreachableReason: "timed out")
        alerts.observe(status: healing([("h-1", .succeeded)]), unreachableReason: nil)
        XCTAssertEqual(poster.posted.map(\.title), ["kinhin fixed a problem", "kinhin fleet not responding"])
    }

    func testFailedAndDismissedFixesPostNothing() {
        let poster = RecordingPoster()
        let alerts = FleetAlerts(poster: poster)
        alerts.observe(status: healing([]), unreachableReason: nil)
        alerts.observe(status: healing([("h-2", .failed), ("h-1", .dismissed)]), unreachableReason: nil)
        XCTAssertTrue(poster.posted.isEmpty)
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
