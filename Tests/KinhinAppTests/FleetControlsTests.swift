import AppKit
import XCTest

@testable import KinhinKit
@testable import kinhin_app

/// `FleetControls`: the one source for Start / Stop / Pause / Resume that the Fleet screen, the status-bar menu and the
/// main menu all read.
@MainActor
final class FleetControlsTests: XCTestCase {
    private func status(running: Bool, paused: Bool = false) -> FleetStatus {
        var s = FleetStatus()
        s.running = running
        s.paused = paused
        return s
    }

    private func controls(_ status: FleetStatus?, pending: FleetAction? = nil) -> FleetControls {
        FleetControls(status: status, pending: pending)
    }

    func testVisibilityPerState() {
        let stopped = controls(status(running: false))
        XCTAssertTrue(stopped.isVisible(.start))
        XCTAssertFalse(stopped.isVisible(.stop) || stopped.isVisible(.pauseResume))
        XCTAssertEqual(controls(nil), stopped, "no status counts as stopped")

        let running = controls(status(running: true))
        XCTAssertTrue(running.isVisible(.stop) && running.isVisible(.pauseResume))
        XCTAssertFalse(running.isVisible(.start) || running.isResume)

        let paused = controls(status(running: true, paused: true))
        XCTAssertTrue(paused.isVisible(.stop) && paused.isVisible(.pauseResume))
        XCTAssertTrue(paused.isResume, "one toggle: it flips to Resume while paused")
    }

    func testTitlesOnTheScreenAndInTheMenu() {
        let running = controls(status(running: true))
        XCTAssertEqual(running.title(.stop), "Stop")
        XCTAssertEqual(running.title(.pauseResume), "Pause")
        XCTAssertEqual(running.title(.stop, on: .menu), "Stop Fleet")
        XCTAssertEqual(running.title(.pauseResume, on: .menu), "Pause Fleet")
        XCTAssertEqual(controls(status(running: false)).title(.start), "Start")
        XCTAssertEqual(controls(status(running: false)).title(.start, on: .menu), "Start Fleet")

        let paused = controls(status(running: true, paused: true))
        XCTAssertEqual(paused.title(.pauseResume), "Resume")
        XCTAssertEqual(paused.title(.pauseResume, on: .menu), "Resume Fleet")
        XCTAssertEqual(paused.menuKey(.pauseResume), "r")
        XCTAssertEqual(running.menuKey(.pauseResume), "p")
    }

    func testPendingStartDisablesEverythingAndTheStartButtonSaysStarting() {
        let starting = controls(status(running: false), pending: .start)
        XCTAssertTrue(starting.isBusy)
        XCTAssertTrue(starting.showsProgress(.start))
        XCTAssertEqual(starting.title(.start), "Starting…")
        XCTAssertEqual(starting.accessibilityLabel(.start), "Starting the fleet")
        for control in FleetControls.Control.allCases {
            XCTAssertFalse(starting.isEnabled(control), "\(control) must be disabled while a command runs")
        }
    }

    func testPendingStopDisablesEverythingAndKeepsTheControlsVisible() {
        let stopping = controls(status(running: true), pending: .stop)
        XCTAssertTrue(stopping.isVisible(.stop) && stopping.isVisible(.pauseResume), "the buttons stay, disabled")
        XCTAssertEqual(stopping.title(.stop), "Stopping…")
        XCTAssertFalse(stopping.showsProgress(.pauseResume))
        XCTAssertFalse(stopping.isEnabled(.stop) || stopping.isEnabled(.pauseResume))
    }

    func testAQueueActionInFlightDisablesControlsWithoutAProgressButton() {
        let busy = controls(status(running: true), pending: .requeueQueuedJobs(for: .github))
        XCTAssertTrue(busy.isBusy)
        XCTAssertFalse(busy.isEnabled(.stop))
        XCTAssertFalse(busy.showsProgress(.stop) || busy.showsProgress(.start))
        XCTAssertEqual(busy.title(.stop), "Stop")
    }

    func testAccessibilityLabelsDifferFromTheVisibleTitles() {
        let running = controls(status(running: true))
        XCTAssertEqual(running.accessibilityLabel(.stop), "Stop the fleet")
        XCTAssertEqual(running.accessibilityLabel(.pauseResume), "Pause the fleet")
        XCTAssertEqual(
            controls(status(running: true, paused: true)).accessibilityLabel(.pauseResume), "Resume the fleet")
    }

    // MARK: - One source for the menu and the screen

    func testMenuValidationAndScreenAgree() {
        let delegate = AppDelegate()
        let menu = delegate.buildMenu()
        // Test-only lookup.
        func item(_ id: String) -> NSMenuItem { menu.items.first { $0.identifier?.rawValue == id }! }

        delegate.fleet.status = status(running: true)
        XCTAssertTrue(delegate.validateMenuItem(item("stopFleet")))
        XCTAssertFalse(delegate.validateMenuItem(item("startFleet")))

        delegate.fleet.pendingFleetAction = .stop
        for id in ["startFleet", "stopFleet", "pauseResumeFleet"] {
            XCTAssertFalse(delegate.validateMenuItem(item(id)), "\(id) disables with the screen's buttons")
        }
        XCTAssertEqual(delegate.fleet.controls, FleetControls(status: delegate.fleet.status, pending: .stop))
    }

    func testMenuItemsTakeTheirTitlesFromTheControls() {
        let delegate = AppDelegate()
        let menu = delegate.buildMenu()
        delegate.menu = menu
        delegate.applyFleetControlVisibility(to: menu, status: status(running: true, paused: true))
        let titles = menu.items.filter {
            ["startFleet", "stopFleet", "pauseResumeFleet"].contains($0.identifier?.rawValue)
        }
        .map(\.title)
        XCTAssertEqual(titles, ["Start Fleet", "Stop Fleet", "Resume Fleet"])
    }
}
