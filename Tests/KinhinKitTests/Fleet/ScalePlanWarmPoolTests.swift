import XCTest

@testable import KinhinKit

final class ScalePlanWarmPoolTests: XCTestCase {
    private let epoch = Date(timeIntervalSince1970: 1_000_000)

    private func record(_ id: String, _ phase: VMPhase, age: TimeInterval = 0) -> VMRecord {
        var record = VMRecord(id: id, phase: phase, createdAt: epoch.addingTimeInterval(age))
        record.platform = phase == .warm ? nil : "github"
        record.runtime = RuntimeID.tart.rawValue
        return record
    }

    private func input(
        records: [VMRecord] = [], queued: Int = 0, warmPool: Int = 2, maxRunners: Int = 4
    ) -> ScalePlan.Input {
        var input = ScalePlan.Input(
            records: records, demand: queued > 0 ? ["github": [.tart: queued]] : [:], attached: ["github"],
            maxRunners: maxRunners, capacityCap: maxRunners, existingPools: [.tart], defaultRuntime: .tart)
        input.warmPool = warmPool
        input.now = epoch.addingTimeInterval(60)
        return input
    }

    func testIdleFleetFillsThePool() {
        let plan = ScalePlan.make(input())
        XCTAssertEqual(plan.warmSpawn, 2)
        XCTAssertTrue(plan.slots.isEmpty)
    }

    func testPoolOffSpawnsNothing() {
        XCTAssertEqual(ScalePlan.make(input(warmPool: 0)).warmSpawn, 0)
    }

    func testExistingWarmInstancesCountTowardThePool() {
        let plan = ScalePlan.make(input(records: [record("w1", .warm)]))
        XCTAssertEqual(plan.warmSpawn, 1)
    }

    func testWarmInstanceIsClaimedInsteadOfCloning() {
        let plan = ScalePlan.make(input(records: [record("w1", .warm)], queued: 1, warmPool: 1))
        XCTAssertEqual(plan.slots.count, 1, "a warm instance is not supply: the job still needs a slot")
        XCTAssertEqual(plan.claims, ["w1"])
        XCTAssertTrue(plan.evict.isEmpty)
        XCTAssertEqual(plan.warmSpawn, 0, "no top-up while demand holds the slots")
    }

    func testOldestWarmInstanceIsClaimedFirst() {
        let records = [record("new", .warm, age: 30), record("old", .warm, age: 0)]
        let plan = ScalePlan.make(input(records: records, queued: 1))
        XCTAssertEqual(plan.claims, ["old"])
    }

    func testWarmInstancesDoNotBlockTheCap() {
        // Cap 2 with two busy VMs, one queued job and a warm instance that occupies no slot a job needs.
        let records = [record("b1", .busy), record("w1", .warm)]
        let plan = ScalePlan.make(input(records: records, queued: 1, warmPool: 1, maxRunners: 2))
        XCTAssertEqual(plan.slots.count, 1)
        XCTAssertEqual(plan.claims, ["w1"])
    }

    func testWarmInstanceIsEvictedWhenTheCapNeedsItsSlot() {
        // A busy VM, a claimed warm one and a spare warm one cannot all fit under a cap of 2.
        let records = [record("b1", .busy), record("w1", .warm), record("w2", .warm, age: 1)]
        let plan = ScalePlan.make(input(records: records, queued: 1, warmPool: 2, maxRunners: 2))
        XCTAssertEqual(plan.claims, ["w1"])
        XCTAssertEqual(plan.evict, ["w2"], "the unclaimed warm instance cannot also fit under the cap")
    }

    func testStaleWarmInstanceIsRecycled() {
        var i = input(records: [record("old", .warm)], warmPool: 1)
        i.now = epoch.addingTimeInterval(3601)
        i.warmMaxAge = 3600
        let plan = ScalePlan.make(i)
        XCTAssertEqual(plan.evict, ["old"])
        XCTAssertTrue(plan.claims.isEmpty)
    }

    func testTopUpLeavesRoomForMinRunners() {
        var i = input(maxRunners: 3)
        i.minRunners = 2
        let plan = ScalePlan.make(i)
        XCTAssertEqual(plan.slots.count, 2)
        XCTAssertEqual(plan.warmSpawn, 0, "min_runners spawns first; the pool only fills leftover slots")
    }

    func testTopUpNeverPassesTheCap() {
        let records = [record("b1", .busy), record("b2", .busy)]
        let plan = ScalePlan.make(input(records: records, warmPool: 4, maxRunners: 3))
        XCTAssertEqual(plan.warmSpawn, 1)
    }

    func testWarmInstancesAreNeverScaleDownTargets() {
        let plan = ScalePlan.make(input(records: [record("w1", .warm)], warmPool: 1))
        XCTAssertTrue(plan.scaleDown.isEmpty)
        XCTAssertTrue(plan.evict.isEmpty)
    }

    func testNoTopUpWhileTheRuntimeBacksOff() {
        var i = input()
        i.heldRuntimes = [.tart]
        XCTAssertEqual(ScalePlan.make(i).warmSpawn, 0)
    }
}
