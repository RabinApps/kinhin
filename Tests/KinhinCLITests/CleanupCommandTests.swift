import XCTest

@testable import KinhinKit
@testable import KinhinTestSupport
@testable import kinhin

final class CleanupCommandTests: XCTestCase {
    private var cacheRoot: URL!

    override func setUpWithError() throws {
        cacheRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("kinhin-cleanup-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: cacheRoot, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: cacheRoot)
    }

    private func makeTart() -> FakeTart {
        let tart = FakeTart()
        tart.vms = [
            "kinhin-1": TartVM(name: "kinhin-1", source: "tahoe-base", status: "running"),
            "kinhin-2": TartVM(name: "kinhin-2", source: "tahoe-base", status: "stopped"),
            "orchard-3": TartVM(name: "orchard-3", source: "tahoe-base", status: "stopped"),
            "tahoe-base": TartVM(name: "tahoe-base", source: "", status: "stopped"),
            "xcode-base": TartVM(name: "xcode-base", source: "tahoe-base", status: "stopped"),
            "my-own-vm": TartVM(name: "my-own-vm", source: "", status: "stopped"),
        ]
        return tart
    }

    func testBareCleanupSelectsEverythingButIsOnlyAPlan() {
        XCTAssertEqual(CleanupCommand.Selection(args: []), CleanupCommand.Selection(args: ["--all"]))
        XCTAssertEqual(
            CleanupCommand.Selection(args: ["--cache"]).vms, false, "an explicit flag narrows the selection")
    }

    func testPlanListsOnlyKinhinVMsAndNeverTheBaseImageAsAVM() async throws {
        let plan = try await CleanupCommand.makePlan(
            selection: .init(args: ["--vms"]), tart: makeTart(), baseImage: "tahoe-base",
            namedImages: ["xcode-base"], cacheRoot: cacheRoot)
        XCTAssertEqual(plan.vms, ["kinhin-1", "kinhin-2", "orchard-3"])
        XCTAssertTrue(plan.images.isEmpty)
    }

    func testNamedImagesArePlannedLikeTheBaseImageAndExcludedFromVMs() async throws {
        let plan = try await CleanupCommand.makePlan(
            selection: .init(args: ["--all"]), tart: makeTart(), baseImage: "tahoe-base",
            namedImages: ["xcode-base"], cacheRoot: cacheRoot)
        XCTAssertEqual(plan.images, ["tahoe-base", "xcode-base"], "base image first, then the images: entries")
        XCTAssertFalse(plan.vms.contains("xcode-base"), "a baked image is not a runner VM")
        // A named image that no longer exists locally is not planned.
        let without = try await CleanupCommand.makePlan(
            selection: .init(args: ["--image"]), tart: makeTart(), baseImage: "tahoe-base",
            namedImages: ["never-baked"], cacheRoot: cacheRoot)
        XCTAssertEqual(without.images, ["tahoe-base"])
    }

    func testImageIsPlannedOnlyWhenRequestedAndPresent() async throws {
        let plan = try await CleanupCommand.makePlan(
            selection: .init(args: ["--image"]), tart: makeTart(), baseImage: "tahoe-base", cacheRoot: cacheRoot)
        XCTAssertEqual(plan.images, ["tahoe-base"])
        XCTAssertTrue(plan.vms.isEmpty)
        let missing = try await CleanupCommand.makePlan(
            selection: .init(args: ["--image"]), tart: makeTart(), baseImage: "not-here", cacheRoot: cacheRoot)
        XCTAssertTrue(missing.images.isEmpty)
    }

    func testExecuteDeletesPlannedItemsAndEmptiesTheCacheButKeepsItsDirectory() async throws {
        try Data(repeating: 1, count: 2048).write(to: cacheRoot.appendingPathComponent("blob"))
        let tart = makeTart()
        let plan = try await CleanupCommand.makePlan(
            selection: .init(args: ["--all"]), tart: tart, baseImage: "tahoe-base",
            namedImages: ["xcode-base"], cacheRoot: cacheRoot)
        try await CleanupCommand.execute(plan, tart: tart, cacheRoot: cacheRoot)

        XCTAssertEqual(Set(tart.deleteCalls), ["kinhin-1", "kinhin-2", "orchard-3", "tahoe-base", "xcode-base"])
        XCTAssertFalse(tart.deleteCalls.contains("my-own-vm"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: cacheRoot.path), "guests mount the directory itself")
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: cacheRoot.path).isEmpty)
    }

    func testDescribeReportsWouldRemoveUntilConfirmed() {
        let plan = CleanupCommand.Plan(vms: ["kinhin-1"], images: [], cacheBytes: nil)
        XCTAssertTrue(CleanupCommand.describe(plan, willDelete: false).contains("would remove"))
        XCTAssertTrue(CleanupCommand.describe(plan, willDelete: true).contains("removing"))
    }

    func testScratchVMsArePlannedSeparatelyFromRunnerVMs() async throws {
        let tart = makeTart()
        tart.vms["kinhin-prepare-tmp-123"] = TartVM(
            name: "kinhin-prepare-tmp-123", source: "tahoe-base", status: "stopped")
        let plan = try await CleanupCommand.makePlan(
            selection: .init(args: ["--vms"]), tart: tart, baseImage: "tahoe-base",
            namedImages: ["xcode-base"], cacheRoot: cacheRoot)
        XCTAssertEqual(plan.scratchVMs, ["kinhin-prepare-tmp-123"])
        XCTAssertEqual(plan.vms, ["kinhin-1", "kinhin-2", "orchard-3"], "scratch VMs are not counted as runner VMs")
    }

    func testExecuteDeletesScratchVMsToo() async throws {
        let tart = makeTart()
        tart.vms["kinhin-prepare-tmp-9"] = TartVM(
            name: "kinhin-prepare-tmp-9", source: "tahoe-base", status: "stopped")
        let plan = try await CleanupCommand.makePlan(
            selection: .init(args: ["--vms"]), tart: tart, baseImage: "tahoe-base", cacheRoot: cacheRoot)
        try await CleanupCommand.execute(plan, tart: tart, cacheRoot: cacheRoot)
        XCTAssertTrue(tart.deleteCalls.contains("kinhin-prepare-tmp-9"))
    }

    func testDescribeCallsBuildScratchOut() {
        let plan = CleanupCommand.Plan(scratchVMs: ["kinhin-prepare-tmp-1"])
        let text = CleanupCommand.describe(plan, willDelete: false)
        XCTAssertTrue(text.contains("image-build scratch"), text)
        XCTAssertTrue(text.contains("crashed or killed bake"), text)
    }

    func testCleanupIsARoutedCommand() {
        XCTAssertEqual(CLICommand.parse(["cleanup", "--yes"]), .cleanup)
    }
}
