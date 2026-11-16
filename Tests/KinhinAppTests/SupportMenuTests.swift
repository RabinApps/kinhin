import AppKit
import XCTest

@testable import kinhin_app

@MainActor
final class SupportMenuTests: XCTestCase {
    func testStatusMenuHasSupportItem() {
        let menu = AppDelegate().buildMenu()
        let item = menu.items.first { $0.identifier?.rawValue == "supportKinhin" }
        XCTAssertEqual(item?.title, "Support kinhin…")
        XCTAssertNotNil(item?.action)
    }

    func testOpenLogsOpensTheLogsPaneNotTheFolder() {
        let menu = AppDelegate().buildMenu()
        let item = menu.items.first { $0.identifier?.rawValue == "openLogs" }
        XCTAssertEqual(item?.title, "Open Logs")
        XCTAssertEqual(item?.action, #selector(AppDelegate.openLogsPane), "named for what it opens: the Logs UI")
    }

    func testSettingsItemOpensTheSettingsSection() {
        let menu = AppDelegate().buildMenu()
        let item = menu.items.first { $0.identifier?.rawValue == "openSettingsTab" }
        XCTAssertEqual(item?.title, "Settings…")
        XCTAssertEqual(item?.action, #selector(AppDelegate.openSettingsTab))
        XCTAssertEqual(item?.keyEquivalent, ",")
    }
}
