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

    func testReportCarriesTheDryRunFacts() {
        let plan = CleanupPlan(
            vms: ["kinhin-1"], scratchVMs: ["kinhin-prepare-tmp-a"], images: ["tahoe-base"], cacheBytes: 2048)
        let report = CleanupCommand.report(for: plan, targets: .init(vms: true))
        XCTAssertFalse(report.empty)
        XCTAssertFalse(report.willDelete, "--json never claims a deletion happened")
        XCTAssertEqual(report.targets, .init(vms: true, image: false, cache: false))
        XCTAssertEqual(report.vms, ["kinhin-1"])
        XCTAssertEqual(report.scratchVMs, ["kinhin-prepare-tmp-a"])
        XCTAssertEqual(report.images, ["tahoe-base"])
        XCTAssertEqual(report.cacheBytes, 2048)
        XCTAssertTrue(report.summary.contains("would remove"), report.summary)
    }

    func testReportOfAnEmptyPlanIsEmpty() {
        let report = CleanupCommand.report(for: CleanupPlan(), targets: .all)
        XCTAssertTrue(report.empty)
        XCTAssertEqual(report.summary, "")
        XCTAssertEqual(report.targets, .init(vms: true, image: true, cache: true))
    }

    /// A broken `tart_path:` skips VMs and images with a warning naming the
    /// path, instead of reading as "nothing to clean up".
    func testBrokenTartPathWarnsInsteadOfSkippingSilently() {
        let (tart, warning) = CleanupCommand.tartController(for: .all, tartPath: "/no/such/tart")
        XCTAssertNil(tart)
        XCTAssertTrue(warning?.contains("/no/such/tart") == true, warning ?? "no warning")
        XCTAssertTrue(warning?.contains("skipped") == true, warning ?? "no warning")

        let (_, cacheOnly) = CleanupCommand.tartController(for: .init(cache: true), tartPath: "/no/such/tart")
        XCTAssertNil(cacheOnly, "a cache-only cleanup does not need tart")
    }
}
