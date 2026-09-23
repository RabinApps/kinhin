import XCTest
import AppKit
import OrchardKit
@testable import orchard_app

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
            "Orchard",
            "Loading…", // statusLine, refreshed by apply(status:)
            "Start Fleet", "Stop Fleet", "Pause", "Resume", "Token Settings…",
            "Check for Updates…",
            "  Orchard \(OrchardVersion.current)",
            "Open Setup…", "Runtimes…", "Open Logs", "Quit",
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
            "statusLine",
            "startFleet", "stopFleet", "pauseFleet", "resumeFleet", "replaceTokenClicked",
            "updateItem",
            "openSetup", "openRuntimes", "openLogs", "quit",
            "vmSectionStart",
        ])
    }

    func testSeparatorsBetweenSections() {
        let items = delegate.buildMenu().items
        // After the title, after the status line, after the fleet controls,
        // and after the update pair. (There is no separator between the
        // version item and "Open Setup…".)
        let separatorIndices = items.indices.filter { items[$0].isSeparatorItem }
        XCTAssertEqual(separatorIndices, [1, 3, 9, 16], "separator placement pins the menu layout")
    }

    // MARK: targeting

    func testFleetActionsTargetTheDelegate() {
        let menu = delegate.buildMenu()
        let expected: [String: Selector] = [
            "Start Fleet": #selector(AppDelegate.startFleet),
            "Stop Fleet": #selector(AppDelegate.stopFleet),
            "Pause": #selector(AppDelegate.pauseFleet),
            "Resume": #selector(AppDelegate.resumeFleet),
            "Token Settings…": #selector(AppDelegate.replaceTokenClicked),
            "Check for Updates…": #selector(AppDelegate.updateItemClicked),
            "Open Setup…": #selector(AppDelegate.openSetup),
            "Runtimes…": #selector(AppDelegate.openRuntimes),
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
        for title in ["Orchard", "Loading…", "  Orchard \(OrchardVersion.current)", "VMs"] {
            let item = items.first { $0.title == title }
            XCTAssertEqual(item?.isEnabled, false, "'\(title)' is display-only and must be disabled")
        }
    }

    func testUpdateItemIsEnabledAndHasNoKeyEquivalent() {
        let item = delegate.buildMenu().items.first { $0.identifier?.rawValue == "updateItem" }
        XCTAssertEqual(item?.isEnabled, true)
        XCTAssertEqual(item?.keyEquivalent, "", "menu bar items should not register global key equivalents")
    }
}
