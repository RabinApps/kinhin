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
}
