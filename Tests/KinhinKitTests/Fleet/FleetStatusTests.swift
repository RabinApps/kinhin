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
}
