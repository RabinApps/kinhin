import AppKit
import KinhinKit
import XCTest

@testable import kinhin_app

@MainActor
final class ForgeIconTests: XCTestCase {
    func testEveryForgeHasATemplateIcon() {
        for forge in ForgeID.allCases {
            guard let image = ForgeIcon.nsImage(for: forge) else {
                XCTFail("no icon for \(forge.rawValue): add Resources/ForgeIcons/\(forge.rawValue).svg")
                continue
            }
            XCTAssertTrue(image.isTemplate, forge.rawValue)
            XCTAssertEqual(image.accessibilityDescription, forge.displayName)
        }
    }

    func testMissingBundleIsNotFound() {
        let empty = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        XCTAssertNil(ForgeIcon.locateBundle(candidates: [nil, empty]))
    }

    func testBundleIsFoundInAnyCandidateDirectory() throws {
        let found = try XCTUnwrap(ForgeIcon.locateBundle())
        let directory = found.bundleURL.deletingLastPathComponent()
        let elsewhere = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        XCTAssertEqual(
            ForgeIcon.locateBundle(candidates: [elsewhere, directory])?.bundleURL.standardizedFileURL,
            found.bundleURL.standardizedFileURL)
    }
}
