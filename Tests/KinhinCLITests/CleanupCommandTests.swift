import XCTest

@testable import KinhinKit
@testable import kinhin

/// The CLI side of `kinhin cleanup`: flag parsing and routing. The plan and
/// deletion logic itself lives in `CleanupPlanTests` (KinhinKitTests).
final class CleanupCommandTests: XCTestCase {
    func testBareCleanupSelectsEverythingButExplicitFlagsNarrow() {
        XCTAssertEqual(CleanupCommand.Selection(args: []).targets, .all)
        XCTAssertEqual(CleanupCommand.Selection(args: ["--all"]).targets, .all)
        XCTAssertEqual(CleanupCommand.Selection(args: ["--cache"]).targets, .init(cache: true))
        XCTAssertEqual(
            CleanupCommand.Selection(args: ["--vms", "--image"]).targets, .init(vms: true, image: true))
    }

    func testCleanupIsARoutedCommand() {
        XCTAssertEqual(CLICommand.parse(["cleanup", "--yes"]), .cleanup)
    }
}
