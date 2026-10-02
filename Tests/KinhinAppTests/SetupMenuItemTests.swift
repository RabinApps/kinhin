import AppKit
import XCTest

@testable import kinhin_app

@MainActor
final class SetupMenuItemTests: XCTestCase {
    private func setupItem(_ menu: NSMenu) -> NSMenuItem? {
        menu.items.first { $0.identifier?.rawValue == "openSetupTab" }
    }

    func testSetupItemIsHiddenOnceSetupIsComplete() {
        let delegate = AppDelegate()
        delegate.setupIncomplete = false
        let menu = delegate.buildMenu()
        XCTAssertEqual(setupItem(menu)?.isHidden, true)
    }

    func testSetupItemShowsWhileSetupIsIncomplete() {
        let delegate = AppDelegate()
        delegate.setupIncomplete = true
        let menu = delegate.buildMenu()
        XCTAssertEqual(setupItem(menu)?.isHidden, false)
        delegate.menu = menu
        delegate.setupIncomplete = false
        XCTAssertEqual(setupItem(menu)?.isHidden, true)
    }
}
