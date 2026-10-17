import AppKit
import XCTest

@testable import KinhinKit
@testable import kinhin_app

@MainActor
final class UpdateMenuTests: XCTestCase {
    private var delegate: AppDelegate!
    private var menu: NSMenu!

    override func setUp() async throws {
        try await super.setUp()
        delegate = AppDelegate()
        menu = delegate.buildMenu()
        delegate.menu = menu  // refreshUpdateItems mutates the stored menu
    }

    private var updateItem: NSMenuItem? {
        menu.items.first { $0.identifier?.rawValue == "updateItem" }
    }

    private var versionItem: NSMenuItem? {
        guard let idx = menu.items.firstIndex(where: { $0.identifier?.rawValue == "updateItem" }),
            menu.items.indices.contains(idx + 1)
        else { return nil }
        return menu.items[idx + 1]
    }

    // MARK: - menu states

    func testNoPendingUpdateHidesUpdateItem() {
        delegate.updates.pendingVersion = nil
        delegate.refreshUpdateItems()

        XCTAssertEqual(updateItem?.isHidden, true)
        XCTAssertEqual(versionItem?.title, "  kinhin \(kinhinVersion.current)")
        XCTAssertEqual(versionItem?.isEnabled, false)
    }

    func testPendingUpdateOffersTheRelease() {
        delegate.updates.pendingVersion = "9.9.9"
        delegate.refreshUpdateItems()

        XCTAssertEqual(updateItem?.title, "Update available — kinhin 9.9.9…")
        XCTAssertEqual(updateItem?.isEnabled, true)
        XCTAssertEqual(updateItem?.isHidden, false)
        XCTAssertEqual(versionItem?.title, "  kinhin \(kinhinVersion.current) (up to date)")
        XCTAssertEqual(versionItem?.isEnabled, false)
    }

    func testPendingUpdateClearsBackToHiddenState() {
        delegate.updates.pendingVersion = "9.9.9"
        delegate.refreshUpdateItems()
        delegate.updates.pendingVersion = nil
        delegate.refreshUpdateItems()

        XCTAssertEqual(updateItem?.isHidden, true)
        XCTAssertEqual(versionItem?.title, "  kinhin \(kinhinVersion.current)")
    }

    // MARK: - feed override policy

    func testFeedOverrideIsReadFromTheEnvironment() {
        XCTAssertEqual(
            UpdatePreferences.feedOverride(fromEnvironment: ["KINHIN_UPDATE_FEED": "http://localhost:8080/appcast.xml"]
            ),
            "http://localhost:8080/appcast.xml")
    }

    func testMissingOrBlankOverrideLeavesTheInfoPlistFeed() {
        XCTAssertNil(UpdatePreferences.feedOverride(fromEnvironment: [:]))
        XCTAssertNil(UpdatePreferences.feedOverride(fromEnvironment: ["KINHIN_UPDATE_FEED": ""]))
        XCTAssertNil(UpdatePreferences.feedOverride(fromEnvironment: ["KINHIN_UPDATE_FEED": "   "]))
    }
}
