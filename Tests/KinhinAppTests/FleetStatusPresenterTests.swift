import AppKit
import XCTest

@testable import KinhinKit
@testable import kinhin_app

/// `FleetStatusPresenter`: the one assembly of the fleet's status text, read by the Fleet screen and the status-bar
/// menu.
@MainActor
final class FleetStatusPresenterTests: XCTestCase {
    private func status(running: Bool, paused: Bool = false) -> FleetStatus {
        var s = FleetStatus()
        s.running = running
        s.paused = paused
        return s
    }

    private func present(
        _ status: FleetStatus?, hasService: Bool = true, unreachable: String? = nil, mode: String? = nil,
        stale: String? = nil, problems: [String] = [], pending: FleetAction? = nil
    ) -> FleetStatusPresenter {
        FleetStatusPresenter(
            .init(
                status: status, hasService: hasService, unreachableReason: unreachable, mode: mode, staleDaemon: stale,
                problems: problems, pending: pending))
    }

    // MARK: - State words

    func testStateWordsAndStyles() {
        let cases: [(FleetStatusPresenter, FleetStatusPresenter.State, String, StatusStyle)] = [
            (present(status(running: true)), .running, "Running", .ok),
            (present(status(running: true, paused: true)), .paused, "Paused", .warn),
            (present(status(running: false)), .stopped, "Stopped", .secondary),
            (present(nil, hasService: false), .needsSetup, "Needs setup", .warn),
            (present(nil, unreachable: "timed out"), .unreachable, "Not responding", .error),
            (present(nil), .checking, "Checking…", .secondary),
            (present(status(running: false), pending: .start), .starting, "Starting…", .warn),
            (present(status(running: true), pending: .stop), .stopping, "Stopping…", .warn),
        ]
        for (presenter, state, word, style) in cases {
            XCTAssertEqual(presenter.state, state)
            XCTAssertEqual(presenter.stateWord, word)
            XCTAssertEqual(presenter.stateStyle, style)
        }
    }

    func testAQueueActionInFlightDoesNotChangeTheStateWord() {
        let presenter = present(status(running: true), pending: .skipQueuedJobs(for: .github))
        XCTAssertEqual(presenter.state, .running)
        XCTAssertFalse(presenter.menuText.hasPrefix("Stopping"), "only a start or stop replaces the menu text")
    }

    // MARK: - Text

    func testHeadlineAndDetailLinesComeFromTheSharedFormatter() {
        var running = status(running: true)
        running.queueDepth = 3
        let presenter = present(running)
        XCTAssertEqual(presenter.headline, FleetStatusFormatter.summary(running).split(separator: "\n")[0].description)
        XCTAssertTrue(presenter.headline.hasPrefix("Running — queue 3"))
        XCTAssertEqual(presenter.stateText, FleetStatusFormatter.summary(running))
    }

    func testStateTextAddsTheModeAndTheStaleDaemonWarning() {
        let presenter = present(
            status(running: true), mode: "background daemon", stale: "LaunchAgent binary is missing")
        let lines = presenter.stateText.split(separator: "\n").map(String.init)
        XCTAssertEqual(lines.suffix(2), ["  background daemon", "  ⚠ LaunchAgent binary is missing"])
    }

    func testNeedsSetupAndUnreachableAndCheckingText() {
        XCTAssertEqual(present(nil, hasService: false).stateText, FleetStatusFormatter.summary(nil))
        XCTAssertEqual(
            present(nil, unreachable: "socket gone").stateText, "Fleet not responding — socket gone")
        XCTAssertEqual(present(nil).stateText, "Checking the fleet…")
    }

    // MARK: - Menu text

    func testMenuTextIsThePendingWordWhileACommandRuns() {
        XCTAssertEqual(present(status(running: false), pending: .start).menuText, "Starting…")
        XCTAssertEqual(present(status(running: true), pending: .stop).menuText, "Stopping…")
    }

    func testMenuTextCarriesProblemsAndTheModeLikeTheScreen() {
        let presenter = present(
            status(running: true), mode: "in-process engine", stale: "stale plist",
            problems: ["Couldn't apply your last settings change"])
        XCTAssertTrue(presenter.menuText.contains("  in-process engine"), "the menu shows the mode too (one assembly)")
        XCTAssertTrue(presenter.menuText.contains("  ⚠ stale plist"))
        XCTAssertTrue(presenter.menuText.hasSuffix("\n  ⚠ Couldn't apply your last settings change"))
    }

    func testBannersAreProblemsAsErrorsThenTheStaleWarning() {
        let presenter = present(status(running: true), stale: "stale plist", problems: ["a", "b"])
        XCTAssertEqual(
            presenter.banners,
            [
                StatusLine(text: "a", style: .error), StatusLine(text: "b", style: .error),
                StatusLine(text: "stale plist", style: .warn),
            ])
    }

    // MARK: - One assembly for both surfaces

    func testMenuAndFleetScreenRenderTheSameStateText() {
        let delegate = AppDelegate()
        var running = status(running: true)
        running.queueDepth = 2
        delegate.fleet.status = running
        delegate.fleet.staleDaemonPlist = "stale plist"
        let screen = delegate.fleet.statusLine
        let menu = delegate.statusLineText(pending: nil, status: running)
        XCTAssertEqual(menu, screen, "the menu and the Fleet screen read one presenter")
        XCTAssertTrue(menu.contains("⚠ stale plist"), "the menu no longer drops the stale-daemon line")
    }

    func testFleetModelFooterReadsThePresenterBanners() {
        let controller = FleetController()
        controller.staleDaemonPlist = "stale plist"
        let model = FleetModel(controller: controller)
        XCTAssertEqual(model.fleetStatusFooter, controller.statusPresenter.banners)
        XCTAssertEqual(model.pauseTitle, controller.controls.title(.pauseResume))
    }
}
