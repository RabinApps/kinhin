import XCTest

@testable import kinhin_app

@MainActor
final class FleetPollerTests: XCTestCase {
    func testCadenceFollowsVisibility() {
        let poller = FleetPoller()
        XCTAssertEqual(poller.currentInterval, poller.idleInterval)
        poller.setMenuOpen(true)
        XCTAssertEqual(poller.currentInterval, poller.activeInterval)
        poller.setMainWindowVisible(true)
        poller.setMenuOpen(false)
        XCTAssertTrue(poller.isUIActive, "the window alone keeps it active")
        poller.setMainWindowVisible(false)
        XCTAssertFalse(poller.isUIActive)
    }

    func testInvalidateStalesInFlightAnswers() {
        let poller = FleetPoller()
        let requested = poller.generation
        XCTAssertTrue(poller.isCurrent(requested))
        poller.invalidate()
        XCTAssertFalse(poller.isCurrent(requested))
    }

    func testOpeningASurfaceWakesTheWaitingLoop() async throws {
        let poller = FleetPoller()
        poller.idleInterval = .seconds(60)
        var polls = 0
        poller.start(poll: { polls += 1 })
        defer { poller.stop() }
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(polls, 1, "one pass, then a long wait")
        poller.setMenuOpen(true)
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertEqual(polls, 2, "opening the menu polls straight away")
    }
}
