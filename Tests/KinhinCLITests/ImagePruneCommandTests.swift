import XCTest

@testable import KinhinKit
@testable import kinhin

/// `kinhin image prune`'s surface: flag parsing, the report-vs-confirm
/// wording, the kept-in-use lines and the closing summary — on injected
/// plans, so no runtime is probed (like the list/delete suite).
final class ImagePruneCommandTests: XCTestCase {
    private func plan(
        images: [ImageDeletePlan.Target] = [], inUse: [ImagePrunePlan.InUse] = [],
        unavailable: [String: String] = [:]
    ) -> ImagePrunePlan {
        ImagePrunePlan(targets: images, inUse: inUse, unavailable: unavailable)
    }

    private func target(
        _ name: String, role: ImageInventory.Role = .local, present: Bool = true, sizeGB: Int? = nil
    ) -> ImageDeletePlan.Target {
        ImageDeletePlan.Target(
            name: name, runtime: .tart, role: role, present: present, stale: !present, sizeGB: sizeGB)
    }

    func testRejectsEverythingButYes() async {
        for args in [["--force"], ["tahoe-base"], ["--yes", "extra"]] {
            do {
                try await ImagePruneCommand.run(args)
                XCTFail("image prune must reject \(args)")
            } catch let error as CLIError {
                XCTAssertEqual(error.exit, .usage)
                XCTAssertTrue(error.message.contains("--yes"), error.message)
            } catch {
                XCTFail("expected CLIError, got \(error)")
            }
        }
    }

    func testDescribeCountsEachKindAndEstimatesTheReclaim() {
        let text = ImagePruneCommand.describe(
            plan(images: [target("old-vm", sizeGB: 5), target("proj-gone", role: .derived, present: false)]),
            willDelete: false)

        XCTAssertTrue(
            text.hasPrefix("would prune 1 unused image(s) and 1 stale record(s) (up to ~5 GB allocated):"),
            text)
        XCTAssertTrue(text.contains("old-vm  (tart, local)  up to 5 GB allocated"), text)
        XCTAssertTrue(
            text.contains("proj-gone  (tart, derived)  stale record — no image on disk"), text)

        let confirmed = ImagePruneCommand.describe(
            plan(images: [target("old-vm", sizeGB: 5)]), willDelete: true)
        XCTAssertTrue(confirmed.hasPrefix("pruning 1 unused image(s) (up to ~5 GB allocated):"), confirmed)
    }

    func testDescribeKeepsInUseImagesVisibleWithTheirRunners() {
        let text = ImagePruneCommand.describe(
            plan(
                images: [target("old-vm")],
                inUse: [.init(name: "source-vm", runtime: .tart, runners: ["kinhin-1", "kinhin-2"])]),
            willDelete: false)

        XCTAssertTrue(
            text.contains("kept source-vm (tart) — in use by 2 runner(s): kinhin-1, kinhin-2"),
            text)
    }

    func testAnEmptyPlanSaysNothingToPrune() {
        XCTAssertEqual(plan().isEmpty, true)
        XCTAssertEqual(
            ImagePruneCommand.summary(for: plan()), "",
            "an empty plan never reaches the summary, but must not invent work")
    }

    func testSummaryNamesWhatWent() {
        let text = ImagePruneCommand.summary(
            for: plan(images: [target("old-vm", sizeGB: 5), target("proj-gone", role: .derived, present: false)]))
        XCTAssertEqual(text, "deleted 1 image(s): old-vm; cleared 1 stale record(s)")
    }
}
