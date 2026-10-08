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
        func title(_ id: String) -> String? {
            menu.items.first { $0.identifier?.rawValue == id }?.title
        }
        delegate.applyFleetControlVisibility(to: menu, status: status(running: true, paused: false))
        XCTAssertEqual(hidden("startFleet"), true)
        XCTAssertEqual(hidden("stopFleet"), false)
        XCTAssertEqual(hidden("pauseResumeFleet"), false)
        XCTAssertEqual(title("pauseResumeFleet"), "Pause")

        delegate.applyFleetControlVisibility(to: menu, status: status(running: true, paused: true))
        XCTAssertEqual(hidden("pauseResumeFleet"), false)
        XCTAssertEqual(title("pauseResumeFleet"), "Resume", "one toggle: the same item flips to Resume")

        delegate.applyFleetControlVisibility(to: menu, status: nil)
        XCTAssertEqual(hidden("startFleet"), false)
        XCTAssertEqual(hidden("stopFleet"), true)
        XCTAssertEqual(hidden("pauseResumeFleet"), true)
    }

    func testMenuHasOnePauseResumeItemAndQuitIsLast() {
        let menu = AppDelegate().buildMenu()
        let ids = menu.items.compactMap { $0.identifier?.rawValue }
        XCTAssertEqual(ids.filter { $0 == "pauseResumeFleet" }.count, 1)
        XCTAssertFalse(ids.contains("pauseFleet") || ids.contains("resumeFleet"))
        XCTAssertEqual(menu.items.last?.title, "Quit")
    }

    func testVMListSitsDirectlyUnderTheStatusLine() {
        let menu = AppDelegate().buildMenu()
        let ids = menu.items.map { $0.identifier?.rawValue }
        let status = ids.firstIndex(of: "statusLine")
        let vms = ids.firstIndex(of: "vmSectionStart")
        XCTAssertNotNil(status)
        XCTAssertEqual(vms, status.map { $0 + 1 }, "the VM header follows the status line")
    }
}
