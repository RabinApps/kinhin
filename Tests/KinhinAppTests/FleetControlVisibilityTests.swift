import AppKit
import XCTest

@testable import KinhinKit
@testable import kinhin_app

@MainActor
final class FleetControlVisibilityTests: XCTestCase {
    private func status(running: Bool, paused: Bool) -> FleetStatus {
        var s = FleetStatus()
        s.running = running
        s.paused = paused
        return s
    }

    func testVisibilityPerState() {
        let stopped = FleetControlVisibility(status: status(running: false, paused: false))
        XCTAssertEqual(stopped, .init(status: nil), "no status counts as stopped")
        XCTAssertTrue(stopped.start)
        XCTAssertFalse(stopped.stop || stopped.pause || stopped.resume)

        let running = FleetControlVisibility(status: status(running: true, paused: false))
        XCTAssertTrue(running.stop && running.pause)
        XCTAssertFalse(running.start || running.resume)

        let paused = FleetControlVisibility(status: status(running: true, paused: true))
        XCTAssertTrue(paused.stop && paused.resume)
        XCTAssertFalse(paused.start || paused.pause)
    }

    func testMenuHidesInapplicableItems() {
        let delegate = AppDelegate()
        let menu = delegate.buildMenu()
        delegate.menu = menu
        func hidden(_ id: String) -> Bool? {
            menu.items.first { $0.identifier?.rawValue == id }?.isHidden
        }
        delegate.applyFleetControlVisibility(to: menu, status: status(running: true, paused: false))
        XCTAssertEqual(hidden("startFleet"), true)
        XCTAssertEqual(hidden("stopFleet"), false)
        XCTAssertEqual(hidden("pauseFleet"), false)
        XCTAssertEqual(hidden("resumeFleet"), true)

        delegate.applyFleetControlVisibility(to: menu, status: nil)
        XCTAssertEqual(hidden("startFleet"), false)
        XCTAssertEqual(hidden("stopFleet"), true)
        XCTAssertEqual(hidden("pauseFleet"), true)
        XCTAssertEqual(hidden("resumeFleet"), true)
    }
}
