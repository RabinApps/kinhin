import XCTest
import AppKit
import KinhinKit
@testable import kinhin_app

@MainActor
final class MenuConstructionTests: XCTestCase {
    private var delegate: AppDelegate!

    override func setUp() {
        super.setUp()
        delegate = AppDelegate()
    }

    // MARK: structure

    func testMenuBuildsWithExpectedItemOrder() {
        let titles = delegate.buildMenu().items.compactMap { item -> String? in
            item.isSeparatorItem ? nil : item.title
        }
        XCTAssertEqual(titles, [
            "kinhin",
            "Loading…", // statusLine, refreshed by apply(status:)
            "Open kinhin",
            "Setup…", "Settings…",
            "Start Fleet", "Stop Fleet", "Pause", "Resume",
            "Check for Updates…",
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
        XCTAssertEqual(identifiers, [
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
            "Check for Updates…": #selector(AppDelegate.updateItemClicked),
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
