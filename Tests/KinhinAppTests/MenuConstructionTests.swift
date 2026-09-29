import AppKit
import XCTest

@testable import KinhinKit
@testable import kinhin_app

@MainActor
final class MenuConstructionTests: XCTestCase {
    private var delegate: AppDelegate!

    override func setUp() async throws {
        try await super.setUp()
        delegate = AppDelegate()
    }

    // MARK: structure

    func testMenuBuildsWithExpectedItemOrder() {
        let titles = delegate.buildMenu().items.compactMap { item -> String? in
            item.isSeparatorItem ? nil : item.title
        }
        XCTAssertEqual(
            titles,
            [
                "kinhin",
                "Loading…",  // statusLine, refreshed by apply(status:)
                "Open kinhin",
                "Setup…", "Settings…",
                "Start Fleet", "Stop Fleet", "Pause", "Resume",
                "Update available…",
                "  kinhin \(kinhinVersion.current)",
                "Open Logs", "Quit",
                "VMs",
            ])
    }

    func testStableIdentifiers() {
        let items = delegate.buildMenu().items
        let identifiers = items.compactMap { $0.identifier?.rawValue }
        // statusLine/vmSectionStart are set explicitly; the action items carry
        // their selector names because AppDelegate subclasses NSMenuItem's
        // target and macOS auto-tags action items during addItem.
        XCTAssertEqual(
            identifiers,
            [
                "statusLine", "openMainWindow",
                "openSetupTab", "openSettingsTab",
                "startFleet", "stopFleet", "pauseFleet", "resumeFleet",
                "updateItem",
                "openLogs", "quit",
                "vmSectionStart",
            ])
    }

    func testSeparatorsBetweenSections() {
        let items = delegate.buildMenu().items
        // After the title, after the status line, after the fleet controls
        // (which include "Open kinhin" and the tab shortcuts), and after the
        // update pair. (No separator between the version item and "Open Logs".)
        let separatorIndices = items.indices.filter { items[$0].isSeparatorItem }
        XCTAssertEqual(separatorIndices, [1, 3, 7, 12, 17], "separator placement pins the menu layout")
    }

    // MARK: targeting

    func testFleetActionsTargetTheDelegate() {
        let menu = delegate.buildMenu()
        let expected: [String: Selector] = [
            "Open kinhin": #selector(AppDelegate.openMainWindow),
            "Setup…": #selector(AppDelegate.openSetupTab),
            "Settings…": #selector(AppDelegate.openSettingsTab),
            "Start Fleet": #selector(AppDelegate.startFleet),
            "Stop Fleet": #selector(AppDelegate.stopFleet),
            "Pause": #selector(AppDelegate.pauseFleet),
            "Resume": #selector(AppDelegate.resumeFleet),
            "Update available…": #selector(AppDelegate.updateItemClicked),
            "Open Logs": #selector(AppDelegate.openLogs),
            "Quit": #selector(AppDelegate.quit),
        ]
        for (title, selector) in expected {
            let item = menu.items.first { $0.title == title }
            XCTAssertNotNil(item, "missing menu item '\(title)'")
            XCTAssertEqual(item?.target as? AppDelegate, delegate, "'\(title)' must target the delegate")
            XCTAssertEqual(item?.action, selector, "'\(title)' must dispatch \(selector)")
        }
    }

    // MARK: inert items

    func testHeaderStatusAndVersionItemsAreDisabled() {
        let items = delegate.buildMenu().items
        for title in ["kinhin", "Loading…", "VMs"] {
            let item = items.first { $0.title == title }
            XCTAssertEqual(item?.isEnabled, false, "'\(title)' is display-only and must be disabled")
        }
    }

    func testOpenKinhinTargetsTheDelegateWithNoKeyEquivalent() {
        let item = delegate.buildMenu().items.first { $0.identifier?.rawValue == "openMainWindow" }
        XCTAssertEqual(item?.isEnabled, true)
        XCTAssertEqual(item?.keyEquivalent, "", "menu bar items should not register global key equivalents")
    }

    func testUpdateItemIsEnabledAndHasNoKeyEquivalent() {
        let item = delegate.buildMenu().items.first { $0.identifier?.rawValue == "updateItem" }
        XCTAssertEqual(item?.isEnabled, true)
        XCTAssertEqual(item?.keyEquivalent, "", "menu bar items should not register global key equivalents")
    }
}

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
