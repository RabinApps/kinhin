import XCTest

@testable import KinhinKit
@testable import KinhinTestSupport

/// The plan/execute/describe logic `kinhin cleanup` and the reset's
/// "everything" scope share. Flag parsing stays in the CLI (`CleanupCommandTests`).
final class CleanupPlanTests: XCTestCase {
    private var cacheRoot: URL!

    override func setUpWithError() throws {
        cacheRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("kinhin-cleanupplan-\(UUID().uuidString)", isDirectory: true)
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

    func testTargetsNarrowThePlan() async throws {
        let onlyVMs = try await CleanupPlan.plan(
            targets: .init(vms: true), tart: makeTart(), baseImage: "tahoe-base",
            namedImages: ["xcode-base"], cacheRoot: cacheRoot)
        XCTAssertEqual(onlyVMs.vms, ["kinhin-1", "kinhin-2", "orchard-3"])
        XCTAssertTrue(onlyVMs.images.isEmpty)
        XCTAssertNil(onlyVMs.cacheBytes)
    }

    func testNamedImagesArePlannedLikeTheBaseImageAndExcludedFromVMs() async throws {
        let plan = try await CleanupPlan.plan(
            targets: .all, tart: makeTart(), baseImage: "tahoe-base",
            namedImages: ["xcode-base"], cacheRoot: cacheRoot)
        XCTAssertEqual(plan.images, ["tahoe-base", "xcode-base"], "base image first, then the images: entries")
        XCTAssertFalse(plan.vms.contains("xcode-base"), "a baked image is not a runner VM")
        // A named image that no longer exists locally is not planned.
        let without = try await CleanupPlan.plan(
            targets: .init(image: true), tart: makeTart(), baseImage: "tahoe-base",
            namedImages: ["never-baked"], cacheRoot: cacheRoot)
        XCTAssertEqual(without.images, ["tahoe-base"])
    }

    func testMissingImageIsNotPlannedAndCacheIsCounted() async throws {
        try Data(repeating: 1, count: 2048).write(to: cacheRoot.appendingPathComponent("blob"))
        let plan = try await CleanupPlan.plan(
            targets: .init(image: true, cache: true), tart: makeTart(), baseImage: "not-here", cacheRoot: cacheRoot)
        XCTAssertTrue(plan.images.isEmpty)
        XCTAssertEqual(plan.cacheBytes, 2048)
        XCTAssertEqual(plan.cacheBytes, CleanupPlan.directoryBytes(cacheRoot))
    }

    func testExecuteDeletesPlannedItemsAndEmptiesTheCacheButKeepsItsDirectory() async throws {
        try Data(repeating: 1, count: 2048).write(to: cacheRoot.appendingPathComponent("blob"))
        let tart = makeTart()
        let plan = try await CleanupPlan.plan(
            targets: .all, tart: tart, baseImage: "tahoe-base",
            namedImages: ["xcode-base"], cacheRoot: cacheRoot)
        try await plan.execute(tart: tart, cacheRoot: cacheRoot)

        XCTAssertEqual(Set(tart.deleteCalls), ["kinhin-1", "kinhin-2", "orchard-3", "tahoe-base", "xcode-base"])
        XCTAssertFalse(tart.deleteCalls.contains("my-own-vm"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: cacheRoot.path), "guests mount the directory itself")
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: cacheRoot.path).isEmpty)
    }

    func testScratchVMsArePlannedSeparatelyFromRunnerVMs() async throws {
        let tart = makeTart()
        tart.vms["kinhin-prepare-tmp-123"] = TartVM(
            name: "kinhin-prepare-tmp-123", source: "tahoe-base", status: "stopped")
        let plan = try await CleanupPlan.plan(
            targets: .init(vms: true), tart: tart, baseImage: "tahoe-base",
            namedImages: ["xcode-base"], cacheRoot: cacheRoot)
        XCTAssertEqual(plan.scratchVMs, ["kinhin-prepare-tmp-123"])
        XCTAssertEqual(plan.vms, ["kinhin-1", "kinhin-2", "orchard-3"], "scratch VMs are not counted as runner VMs")
    }

    func testExecuteDeletesScratchVMsToo() async throws {
        let tart = makeTart()
        tart.vms["kinhin-prepare-tmp-9"] = TartVM(
            name: "kinhin-prepare-tmp-9", source: "tahoe-base", status: "stopped")
        let plan = try await CleanupPlan.plan(
            targets: .init(vms: true), tart: tart, baseImage: "tahoe-base", cacheRoot: cacheRoot)
        try await plan.execute(tart: tart, cacheRoot: cacheRoot)
        XCTAssertTrue(tart.deleteCalls.contains("kinhin-prepare-tmp-9"))
    }

    func testDescribeReportsWouldRemoveUntilConfirmed() {
        let plan = CleanupPlan(vms: ["kinhin-1"])
        XCTAssertTrue(plan.describe(willDelete: false).contains("would remove"))
        XCTAssertTrue(plan.describe(willDelete: true).contains("removing"))
    }

    func testDescribeCallsBuildScratchOut() {
        let plan = CleanupPlan(scratchVMs: ["kinhin-prepare-tmp-1"])
        let text = plan.describe(willDelete: false)
        XCTAssertTrue(text.contains("image-build scratch"), text)
        XCTAssertTrue(text.contains("crashed or killed bake"), text)
    }
}
