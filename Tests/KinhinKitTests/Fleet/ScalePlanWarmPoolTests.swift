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
        input.warmPool = warmPool > 0 ? ["": warmPool] : [:]
        input.now = epoch.addingTimeInterval(60)
        return input
    }

    func testIdleFleetFillsThePool() {
        let plan = ScalePlan.make(input())
        XCTAssertEqual(plan.warmTotal, 2)
        XCTAssertTrue(plan.slots.isEmpty)
    }

    func testPoolOffSpawnsNothing() {
        XCTAssertEqual(ScalePlan.make(input(warmPool: 0)).warmTotal, 0)
    }

    func testExistingWarmInstancesCountTowardThePool() {
        let plan = ScalePlan.make(input(records: [record("w1", .warm)]))
        XCTAssertEqual(plan.warmTotal, 1)
    }

    func testWarmInstanceIsClaimedInsteadOfCloning() {
        let plan = ScalePlan.make(input(records: [record("w1", .warm)], queued: 1, warmPool: 1))
        XCTAssertEqual(plan.slots.count, 1, "a warm instance is not supply: the job still needs a slot")
        XCTAssertEqual(plan.claims, ["w1"])
        XCTAssertTrue(plan.evict.isEmpty)
        XCTAssertEqual(plan.warmTotal, 0, "no top-up while demand holds the slots")
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
        XCTAssertEqual(plan.warmTotal, 0, "min_runners spawns first; the pool only fills leftover slots")
    }

    func testTopUpNeverPassesTheCap() {
        let records = [record("b1", .busy), record("b2", .busy)]
        let plan = ScalePlan.make(input(records: records, warmPool: 4, maxRunners: 3))
        XCTAssertEqual(plan.warmTotal, 1)
    }

    func testWarmInstancesAreNeverScaleDownTargets() {
        let plan = ScalePlan.make(input(records: [record("w1", .warm)], warmPool: 1))
        XCTAssertTrue(plan.scaleDown.isEmpty)
        XCTAssertTrue(plan.evict.isEmpty)
    }

    func testNoTopUpWhileTheRuntimeBacksOff() {
        var i = input()
        i.heldRuntimes = [.tart]
        XCTAssertEqual(ScalePlan.make(i).warmTotal, 0)
    }

    // MARK: - Per-image pools

    private func imageRecord(_ id: String, _ phase: VMPhase, image: String?) -> VMRecord {
        var record = record(id, phase)
        record.image = image
        return record
    }

    func testJobForAnImageClaimsOnlyItsOwnWarmInstance() {
        let records = [imageRecord("base", .warm, image: nil), imageRecord("xcode", .warm, image: "xcode")]
        var i = input(records: records, queued: 1)
        i.imageDemand = ["xcode": 1]
        i.warmPool = ["": 1, "xcode": 1]
        let plan = ScalePlan.make(i)
        XCTAssertEqual(plan.slots.first?.image, "xcode")
        XCTAssertEqual(plan.slots.first?.claim, "xcode")
        XCTAssertEqual(plan.claims, ["xcode"])
        XCTAssertTrue(plan.evict.isEmpty, "the base warm instance is kept, not claimed by the Xcode job")
    }

    func testBaseJobDoesNotClaimAnImageWarmInstance() {
        var i = input(records: [imageRecord("xcode", .warm, image: "xcode")], queued: 1)
        i.warmPool = ["xcode": 1]
        let plan = ScalePlan.make(i)
        XCTAssertNil(plan.slots.first?.image)
        XCTAssertNil(plan.slots.first?.claim)
        XCTAssertTrue(plan.claims.isEmpty)
    }

    func testIdleFleetTopsUpEachImageSeparately() {
        var i = input(maxRunners: 4)
        i.warmPool = ["": 1, "xcode": 2]
        XCTAssertEqual(ScalePlan.make(i).warmSpawn, ["": 1, "xcode": 2])
    }

    func testImageTopUpCountsOnlyItsOwnWarmInstances() {
        var i = input(records: [imageRecord("x1", .warm, image: "xcode")], maxRunners: 4)
        i.warmPool = ["xcode": 2]
        XCTAssertEqual(ScalePlan.make(i).warmSpawn, ["xcode": 1])
    }

    func testWarmVMOfARemovedImageIsRecycledNow() {
        // The xcode images: entry was removed, so its warm VM is evicted at once instead of holding a slot
        // until warm_max_age, and the base pool still fills.
        var i = input(records: [imageRecord("x1", .warm, image: "xcode")], maxRunners: 4)
        i.warmPool = ["": 1]
        let plan = ScalePlan.make(i)
        XCTAssertEqual(plan.evict, ["x1"])
        XCTAssertEqual(plan.warmSpawn, ["": 1])
    }

    // MARK: - In-flight pooled instances

    private func pooled(_ id: String, _ phase: VMPhase, image: String = "") -> VMRecord {
        // Real pooled records have no account until they are claimed for a job.
        var record = imageRecord(id, phase, image: image.isEmpty ? nil : image)
        record.platform = nil
        record.pooled = true
        return record
    }

    func testAnInFlightPooledInstanceCountsTowardItsPoolTarget() {
        // Pool of 1 with one instance still cloning: a second spawn would be why `warm_pool: 1` keeps 2 VMs.
        let plan = ScalePlan.make(input(records: [pooled("p1", .cloning)], warmPool: 1))
        XCTAssertEqual(plan.warmTotal, 0, "the in-flight instance holds its pool target")
        XCTAssertTrue(plan.slots.isEmpty)
        XCTAssertTrue(plan.evict.isEmpty, "an in-flight instance is not evicted while it should still arrive")
    }

    func testInFlightPooledInstancesCountPerImage() {
        var i = input(records: [pooled("p1", .cloning, image: "xcode")], maxRunners: 4)
        i.warmPool = ["": 1, "xcode": 2]
        XCTAssertEqual(ScalePlan.make(i).warmSpawn, ["": 1, "xcode": 1], "only the base pool is short")
    }

    func testInFlightPooledInstancesDoNotScaleTheFleet() {
        let plan = ScalePlan.make(input(records: [pooled("p1", .cloning)], warmPool: 1))
        XCTAssertEqual(plan.active, 0, "a pooled instance serves no demand")
        XCTAssertEqual(plan.target, 0)
    }

    func testInFlightPooledInstancesReserveRoomUnderTheCap() {
        // Two busy VMs under a cap of 3 with one in-flight pooled clone: the top-up must not
        // plan new instances as if the in-flight clone would not also need a slot.
        let records = [record("b1", .busy), record("b2", .busy), pooled("p1", .booting)]
        let plan = ScalePlan.make(input(records: records, warmPool: 2, maxRunners: 3))
        XCTAssertEqual(plan.warmSpawn, [:], "the cap already holds the two busy VMs and the clone")
    }

    func testAQueuedJobBesideAnInFlightPooledCloneDoesNotPassTheCap() {
        // One busy VM and one pooled clone still booting, cap 3, one queued job:
        // the eager clone is not evictable supply, so only one demand slot may
        // spawn (busy + slot + clone = 3). Two slots would exceed the cap.
        let records = [record("b1", .busy), pooled("p1", .cloning)]
        let plan = ScalePlan.make(input(records: records, queued: 1, warmPool: 1, maxRunners: 3))
        XCTAssertEqual(plan.slots.count, 1, "the in-flight clone reserves its slot under the cap")
        XCTAssertEqual(plan.warmTotal, 0)
    }

    func testChooseImagePrefersTheImageWithUnmetDemand() {
        XCTAssertEqual(ScalePlan.chooseImage(queuedTart: 1, byImage: ["xcode": 1], active: [:]), "xcode")
        XCTAssertNil(
            ScalePlan.chooseImage(queuedTart: 3, byImage: ["xcode": 1], active: [:]), "base has the most unmet")
        XCTAssertNil(ScalePlan.chooseImage(queuedTart: 1, byImage: ["xcode": 1], active: ["xcode": 1]))
    }
}

extension ScalePlan {
    /// Warm instances to start across every pool.
    fileprivate var warmTotal: Int { warmSpawn.values.reduce(0, +) }
}
