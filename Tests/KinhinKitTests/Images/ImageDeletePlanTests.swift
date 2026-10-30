import XCTest

@testable import KinhinKit
@testable import KinhinTestSupport

/// `ImageDeletePlan` — resolving requested names into targets and refusals,
/// and the delete itself (tart + the derived-image index), with the fake tart
/// and a temp-directory store.
final class ImageDeletePlanTests: XCTestCase {
    private var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("kinhin-idp-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: dir)  // test temp dir
    }

    private func config(image: String = "tahoe-base") -> KinhinConfig {
        var cfg = KinhinConfig.default
        cfg.image = image
        return cfg
    }

    private func record(_ name: String) -> ProjectImageRecord {
        ProjectImageRecord(
            name: name, key: name, base: "tahoe-base", summary: "go@1.22.5",
            createdAt: Date(timeIntervalSince1970: 0), lastUsedAt: Date(timeIntervalSince1970: 1000),
            toolchains: .init(KinhinConfig.ToolchainsConfig()), shareCache: false)
    }

    private func store(with names: [String]) -> ProjectImageStore {
        let store = ProjectImageStore(directory: dir)
        for name in names { store.upsert(record(name)) }
        return store
    }

    func testOneNameMatchingTwoRuntimesDeletesItInBoth() {
        var cfg = config()
        cfg.container = .init(image: "shared")
        cfg.docker = .init(image: "shared")
        let inventory = ImageInventory.build(
            config: cfg,
            tart: .init(names: ["shared"]),
            container: .init(names: ["shared"]),
            docker: .init(names: ["shared"]))

        let plan = ImageDeletePlan.plan(names: ["shared"], inventory: inventory)
        XCTAssertEqual(plan.refusals, [])
        XCTAssertEqual(plan.targets.map(\.runtime), [.tart, .container, .docker])
    }

    func testAnImageRunnersAreUsingIsRefusedWithTheFix() {
        let inventory = ImageInventory.build(
            config: config(), tart: .init(names: ["tahoe-base"]),
            fleet: [vmRecord("kinhin-1")])

        let plan = ImageDeletePlan.plan(names: ["tahoe-base"], inventory: inventory, fleet: [vmRecord("kinhin-1")])
        XCTAssertEqual(plan.targets, [])
        XCTAssertEqual(plan.refusals.count, 1)
        XCTAssertEqual(plan.refusals[0].kind, .inUse)
        XCTAssertTrue(plan.refusals[0].reason.contains("kinhin-1"), plan.refusals[0].reason)
        XCTAssertTrue(plan.refusals[0].reason.contains("kinhin stop"), plan.refusals[0].reason)
    }

    func testAnUnknownNameSuggestsCloseMatches() {
        let inventory = ImageInventory.build(config: config(), tart: .init(names: ["tahoe-base", "xcode"]))

        let plan = ImageDeletePlan.plan(names: ["tahoe-bas"], inventory: inventory)
        XCTAssertEqual(plan.targets, [])
        XCTAssertEqual(plan.refusals[0].kind, .unknown)
        XCTAssertTrue(plan.refusals[0].reason.contains("did you mean: tahoe-base"), plan.refusals[0].reason)
        XCTAssertTrue(plan.refusals[0].reason.contains("kinhin image list"), plan.refusals[0].reason)
    }

    func testARunnerVMNameIsNotAnImage() {
        let inventory = ImageInventory.build(config: config(), tart: .init(names: ["tahoe-base"]))

        let plan = ImageDeletePlan.plan(
            names: ["kinhin-1717-abcd", "kinhin-prepare-tmp-9"], inventory: inventory,
            fleet: [vmRecord("kinhin-1717-abcd")])
        XCTAssertEqual(plan.targets, [])
        XCTAssertEqual(plan.refusals.map(\.kind), [.notAnImage, .notAnImage])
        for refusal in plan.refusals {
            XCTAssertTrue(refusal.reason.contains("cleanup --vms"), refusal.reason)
        }
    }

    func testAStaleDerivedRecordIsAnIndexOnlyTarget() {
        let inventory = ImageInventory.build(
            config: config(), tart: .init(names: ["tahoe-base"]), projectRecords: [record("proj-gone")])

        let plan = ImageDeletePlan.plan(names: ["proj-gone"], inventory: inventory)
        XCTAssertEqual(plan.refusals, [])
        XCTAssertEqual(plan.targets.count, 1)
        XCTAssertEqual(plan.targets[0].present, false)
        XCTAssertEqual(plan.targets[0].stale, true)
        XCTAssertEqual(plan.targets[0].role, .derived)
    }

    func testExecutingDeletesTheTartImageAndClearsItsIndexEntry() async throws {
        let store = store(with: ["proj-abc"])
        let tart = FakeTart()
        tart.vms["proj-abc"] = TartVM(name: "proj-abc", source: "tahoe-base", status: "stopped")
        let inventory = ImageInventory.build(
            config: config(), tart: .init(names: ["tahoe-base", "proj-abc"]),
            projectRecords: [record("proj-abc")])

        let plan = ImageDeletePlan.plan(names: ["proj-abc"], inventory: inventory)
        try await plan.execute(tart: tart, container: nil, docker: nil, store: store)

        XCTAssertEqual(tart.deleteCalls, ["proj-abc"])
        XCTAssertEqual(store.all, [], "the index must not keep a record for a deleted image")
    }

    func testExecutionContinuesAfterFailureAndAggregatesAtTheEnd() async throws {
        let store = store(with: ["proj-failed", "proj-good"])
        let tart = FakeTart()
        tart.vms["proj-failed"] = TartVM(name: "proj-failed", source: "base", status: "stopped")
        tart.vms["proj-good"] = TartVM(name: "proj-good", source: "base", status: "stopped")
        tart.failNext("delete", stderr: "disk busy")
        let plan = ImageDeletePlan(
            targets: [
                .init(name: "proj-failed", runtime: .tart, role: .derived, present: true),
                .init(name: "proj-good", runtime: .tart, role: .derived, present: true),
            ], refusals: [])

        do {
            try await plan.execute(tart: tart, container: nil, docker: nil, store: store)
            XCTFail("the failed deletion must be reported after trying the remaining target")
        } catch let error as ImageError {
            guard case .deletionFailed(let failures) = error else { return XCTFail("wrong error: \(error)") }
            XCTAssertEqual(failures.count, 1)
            XCTAssertTrue(failures[0].contains("proj-failed"), failures[0])
        }
        XCTAssertEqual(tart.deleteCalls, ["proj-good"], "the second target is attempted despite the first failure")
        XCTAssertEqual(
            store.all.map(\.name), ["proj-failed"],
            "the succeeded record is cleared; the failed target keeps its record for a retry")
    }

    func testDeletingAnAlreadyMissingTartImageIsSuccess() async throws {
        let tart = FakeTart()
        tart.strictMissing = true
        let plan = ImageDeletePlan(
            targets: [
                .init(name: "gone", runtime: .tart, role: .local, present: true)
            ], refusals: [])
        try await plan.execute(tart: tart, container: nil, docker: nil, store: store(with: []))
        XCTAssertTrue(tart.deleteCalls.isEmpty)
    }

    func testExecutingAStaleRecordOnlyTouchesTheIndex() async throws {
        let store = store(with: ["proj-gone"])
        let tart = FakeTart()
        let inventory = ImageInventory.build(
            config: config(), tart: .init(names: ["tahoe-base"]), projectRecords: [record("proj-gone")])

        let plan = ImageDeletePlan.plan(names: ["proj-gone"], inventory: inventory)
        try await plan.execute(tart: tart, container: nil, docker: nil, store: store)

        XCTAssertEqual(tart.deleteCalls, [], "there is no image left to delete")
        XCTAssertEqual(store.all, [])
    }

    func testExecutingWithoutTheRuntimeItNeedsFailsLoudly() async throws {
        let inventory = ImageInventory.build(
            config: config(), tart: .init(names: ["tahoe-base"]), container: .init(names: ["shared"]))
        let plan = ImageDeletePlan.plan(names: ["shared"], inventory: inventory)

        do {
            try await plan.execute(tart: FakeTart(), container: nil, docker: nil, store: store(with: []))
            XCTFail("deleting a container image without the container CLI must fail")
        } catch let error as ImageError {
            guard case .deletionFailed(let failures) = error else { return XCTFail("wrong error: \(error)") }
            XCTAssertEqual(failures.count, 1)
            XCTAssertTrue(failures[0].contains("the container CLI is not available"), failures[0])
        } catch {
            XCTFail("expected ImageError.runtimeUnavailable, got \(error)")
        }
    }

    func testExecutingAKnownImageWithoutTartFailsLoudly() async throws {
        let inventory = ImageInventory.build(config: config(), tart: .init(names: ["tahoe-base"]))
        let plan = ImageDeletePlan.plan(names: ["tahoe-base"], inventory: inventory)

        do {
            try await plan.execute(tart: nil, container: nil, docker: nil, store: store(with: []))
            XCTFail("deleting a tart image without tart must fail")
        } catch let error as ImageError {
            guard case .deletionFailed(let failures) = error else { return XCTFail("wrong error: \(error)") }
            XCTAssertEqual(failures.count, 1)
            XCTAssertTrue(failures[0].contains("tart is not installed"), failures[0])
        } catch {
            XCTFail("expected ImageError.runtimeUnavailable, got \(error)")
        }
    }

    private func vmRecord(_ id: String, image: String? = nil) -> VMRecord {
        var record = VMRecord(id: id)
        record.image = image
        return record
    }

    func testRefusesAnImageWhoseRuntimeInstancesCouldNotBeListed() {
        let inventory = ImageInventory.build(
            config: config(), tart: .init(names: ["tahoe-base"]),
            docker: .init(names: ["old:1"], usageUnknown: "could not list docker instances: boom"))

        let plan = ImageDeletePlan.plan(names: ["old:1"], inventory: inventory)

        XCTAssertEqual(plan.targets, [])
        XCTAssertEqual(plan.refusals.map(\.kind), [.inUse])
        XCTAssertTrue(plan.refusals[0].reason.contains("could not list docker instances: boom"))
    }
}
