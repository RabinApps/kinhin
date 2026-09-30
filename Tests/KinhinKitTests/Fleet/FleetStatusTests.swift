import XCTest

@testable import KinhinKit

/// The pure FleetStatus helpers the paused/auto-resume surfaces share.
final class FleetStatusTests: XCTestCase {
    private func paused(autoResume: Bool? = true, pollInterval: Int? = nil) -> FleetStatus {
        var status = FleetStatus()
        status.running = true
        status.paused = true
        status.autoResume = autoResume
        status.pollInterval = pollInterval
        return status
    }

    func testCadenceNamesTheNextQueueCheck() {
        XCTAssertEqual(
            paused(pollInterval: 20).autoResumeCadence,
            "re-checks the queue every 20s and resumes once it's empty")
    }

    func testCadenceIsNilWhenTheHintDoesNotApply() {
        XCTAssertNil(paused(autoResume: false, pollInterval: 20).autoResumeCadence, "policy off")
        XCTAssertNil(paused(autoResume: nil, pollInterval: 20).autoResumeCadence, "older daemon: policy unknown")
        XCTAssertNil(paused(pollInterval: nil).autoResumeCadence, "cadence unknown: surfaces keep the short wording")
    }

    func testCadenceNeedsThePause() {
        var running = FleetStatus()
        running.running = true
        running.autoResume = true
        running.pollInterval = 20
        XCTAssertNil(running.autoResumeCadence)
    }

    // MARK: - queue age

    func testQueueAgeCountsSinceTheLastAnsweredPoll() {
        var status = FleetStatus()
        status.queuePolledAt = Date().addingTimeInterval(-7)
        XCTAssertEqual(
            status.queueAgeSeconds.map { $0 >= 7 }, true, "at least 7s old, got: \(status.queueAgeSeconds ?? -1)")
    }

    func testQueueAgeIsNilWhenNeverPolled() {
        XCTAssertNil(FleetStatus().queueAgeSeconds, "no observation to date an age from")
    }

    func testQueueAgeClampsClockSkewToZero() {
        var status = FleetStatus()
        status.queuePolledAt = Date().addingTimeInterval(30)
        XCTAssertEqual(status.queueAgeSeconds, 0, "a slightly-future stamp must not read negative")
    }

    func testQueueAgeIsStalePastThePollCadence() {
        var status = FleetStatus()
        status.pollInterval = 300
        status.queuePolledAt = Date().addingTimeInterval(-1)
        XCTAssertEqual(status.queueAgeIsStale, false, "inside the cadence: fresh")

        status.queuePolledAt = Date().addingTimeInterval(-301)
        XCTAssertEqual(status.queueAgeIsStale, true, "older than the cadence: a poll likely failed")
    }

    /// An idle backoff is not staleness: the age is judged against the
    /// cadence in effect.
    func testQueueAgeIsJudgedAgainstTheCurrentCadence() {
        var status = FleetStatus()
        status.pollInterval = 20
        status.currentPollInterval = 60
        status.queuePolledAt = Date().addingTimeInterval(-45)
        XCTAssertEqual(status.queueAgeIsStale, false)
        status.queuePolledAt = Date().addingTimeInterval(-61)
        XCTAssertEqual(status.queueAgeIsStale, true)
    }

    func testQueueAgeStalenessNeedsAnAge() {
        XCTAssertNil(FleetStatus().queueAgeIsStale, "never polled: neither fresh nor stale")
    }

    func testQueueAgeWithoutAKnownCadenceIsStaleOnceAged() {
        var status = FleetStatus()
        status.pollInterval = nil  // older daemon: the CLI's `?? 0` rule
        status.queuePolledAt = Date().addingTimeInterval(-1)
        XCTAssertEqual(status.queueAgeIsStale, true, "any nonzero age is stale without a cadence")
    }

    func testInitStoresRuntimeFields() {
        let status = FleetStatus(runtime: "tart", capacityByRuntime: ["tart": "2", "appleContainer": "1"])
        XCTAssertEqual(status.runtime, "tart")
        XCTAssertEqual(status.capacityByRuntime, ["tart": "2", "appleContainer": "1"])
    }
}
