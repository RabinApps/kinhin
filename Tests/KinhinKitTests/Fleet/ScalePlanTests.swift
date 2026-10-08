import XCTest

@testable import KinhinKit

final class ScalePlanTests: XCTestCase {
    private func record(
        _ id: String, _ phase: VMPhase, account: String = "github", runtime: RuntimeID = .tart, age: TimeInterval = 0
    ) -> VMRecord {
        var record = VMRecord(id: id, phase: phase, createdAt: Date(timeIntervalSince1970: 1_000_000 + age))
        record.platform = account
        record.runtime = runtime.rawValue
        return record
    }

    private func input(
        records: [VMRecord] = [], demand: [String: [RuntimeID: Int]], maxRunners: Int = 4, capacity: Int = 4,
        pools: Set<RuntimeID> = [.tart]
    ) -> ScalePlan.Input {
        ScalePlan.Input(
            records: records, demand: demand, attached: demand.isEmpty ? ["github"] : Set(demand.keys),
            maxRunners: maxRunners, capacityCap: capacity, existingPools: pools, defaultRuntime: .tart)
    }

    // MARK: - Busy versus queued (classic forges)

    func testBusyVMsDoNotCoverQueuedJobs() {
        let plan = ScalePlan.make(
            input(
                records: [record("a", .busy), record("b", .busy)], demand: ["github": [.tart: 2]]))
        XCTAssertEqual(plan.slots.count, 2, "two queued jobs need two new VMs next to the two busy ones")
        XCTAssertEqual(plan.target, 4)
    }

    func testReadyVMCoversAQueuedJobAndBusyDoesNot() {
        let plan = ScalePlan.make(
            input(records: [record("a", .busy), record("b", .ready)], demand: ["github": [.tart: 1]]))
        XCTAssertTrue(plan.slots.isEmpty)
        XCTAssertTrue(plan.scaleDown.isEmpty, "the ready VM is the one serving the queued job")
    }

    func testBootingVMsCountAsComing() {
        let plan = ScalePlan.make(
            input(records: [record("a", .booting), record("b", .cloning)], demand: ["github": [.tart: 3]]))
        XCTAssertEqual(plan.slots.count, 1)
    }

    func testTargetNeverPassesTheCap() {
        let plan = ScalePlan.make(
            input(records: (0..<3).map { record("b\($0)", .busy) }, demand: ["github": [.tart: 5]]))
        XCTAssertEqual(plan.slots.count, 1)
        XCTAssertEqual(plan.target, 4)
    }

    func testCapacityCapBindsBeforeMax() {
        let plan = ScalePlan.make(input(demand: ["github": [.tart: 9]], maxRunners: 8, capacity: 2))
        XCTAssertEqual(plan.slots.count, 2)
        XCTAssertEqual(plan.desired, 2)
    }

    func testRunnersPerVMDividesQueuedDemand() {
        var i = input(records: [record("a", .busy)], demand: ["github": [.tart: 5]])
        i.runnersPerVM = 2
        XCTAssertEqual(ScalePlan.make(i).slots.count, 3, "5 jobs at 2 per VM need 3 free VMs; the busy one covers none")
    }

    func testMinRunnersFloorsTheTarget() {
        var i = input(demand: [:])
        i.minRunners = 2
        let plan = ScalePlan.make(i)
        XCTAssertEqual(plan.slots.map(\.runtime), [.tart, .tart], "warm floor lands on the default runtime")
    }

    // MARK: - Scale-set (demand includes running jobs)

    func testScaleSetBusyVMsCoverTheirOwnJob() {
        var i = input(records: [record("a", .busy), record("b", .busy)], demand: ["github": [.tart: 2]])
        i.includesRunning = ["github"]
        let plan = ScalePlan.make(i)
        XCTAssertTrue(plan.slots.isEmpty, "two assigned jobs, two busy VMs: nothing more to start")
    }

    func testScaleSetStartsOnlyForTheUncoveredJobs() {
        var i = input(records: [record("a", .busy)], demand: ["github": [.tart: 3]])
        i.includesRunning = ["github"]
        XCTAssertEqual(ScalePlan.make(i).slots.count, 2)
    }

    func testMixedKindsAreCoveredSeparately() {
        // A classic account with one queued job and a scale-set account with
        // one assigned (running) job: the busy scale-set VM covers its own job,
        // the classic job still needs a VM.
        var i = input(
            records: [record("s1", .busy, account: "scaleset")],
            demand: ["classic": [.tart: 1], "scaleset": [.tart: 1]])
        i.includesRunning = ["scaleset"]
        let plan = ScalePlan.make(i)
        XCTAssertEqual(plan.slots, [ScalePlan.Slot(account: "classic", runtime: .tart)])
    }

    // MARK: - Pools

    func testTwoPoolsEachGetTheirOwnUnmetDemand() {
        let plan = ScalePlan.make(
            input(
                records: [record("a", .busy, runtime: .tart), record("b", .busy, runtime: .appleContainer)],
                demand: ["github": [.tart: 1, .appleContainer: 1]], pools: [.tart, .appleContainer]))
        XCTAssertEqual(Set(plan.slots.map(\.runtime)), [.tart, .appleContainer])
        XCTAssertEqual(plan.slots.count, 2)
    }

    func testIdleInstanceInOnePoolDoesNotHideAJobInTheOther() {
        let plan = ScalePlan.make(
            input(
                records: [record("a", .ready, runtime: .appleContainer)],
                demand: ["github": [.tart: 1]], pools: [.tart, .appleContainer]))
        XCTAssertEqual(plan.slots.map(\.runtime), [.tart])
        XCTAssertTrue(plan.scaleDown.isEmpty, "desired is 1 and active 1; the other pool's job is not served by it")
    }

    func testPoolAtItsCapDoesNotInflateTheTarget() {
        var i = input(
            records: [record("a", .busy, runtime: .appleContainer), record("b", .busy, runtime: .appleContainer)],
            demand: ["github": [.appleContainer: 2]], pools: [.tart, .appleContainer])
        i.poolCaps = [.appleContainer: 2, .tart: 2]
        let plan = ScalePlan.make(i)
        XCTAssertTrue(plan.slots.isEmpty, "the container partition is full; two busy VMs never spill over to tart")
        XCTAssertEqual(plan.target, 2)
    }

    func testPartitionRoomIsRespectedAcrossSlots() {
        var i = input(demand: ["github": [.appleContainer: 3]], pools: [.tart, .appleContainer])
        i.poolCaps = [.appleContainer: 2, .tart: 2]
        let plan = ScalePlan.make(i)
        XCTAssertEqual(plan.slots.filter { $0.runtime == .appleContainer }.count, 2)
    }

    func testHeldRuntimeSpawnsNothingAndDoesNotInflate() {
        var i = input(demand: ["github": [.tart: 2, .appleContainer: 1]], pools: [.tart, .appleContainer])
        i.heldRuntimes = [.tart]
        let plan = ScalePlan.make(i)
        XCTAssertEqual(plan.slots.map(\.runtime), [.appleContainer], "only the pool that is not backing off spawns")
    }

    func testSelectRuntimeMostUnmetThenAlphabeticalThenFallback() {
        let exists: (RuntimeID) -> Bool = { _ in true }
        XCTAssertEqual(
            ScalePlan.selectRuntime(
                unmet: [.tart: 1, .appleContainer: 2], active: [:], caps: [:], fallback: .tart, poolExists: exists),
            .appleContainer)
        XCTAssertEqual(
            ScalePlan.selectRuntime(unmet: [:], active: [:], caps: [:], fallback: .docker, poolExists: exists), .docker)
    }

    // MARK: - Accounts

    func testNewInstanceGoesToTheAccountWithTheMostUnmetDemand() {
        let plan = ScalePlan.make(
            input(
                records: [record("a", .ready, account: "work")],
                demand: ["work": [.tart: 1], "side": [.tart: 3]]))
        XCTAssertEqual(plan.slots.first?.account, "side")
    }

    func testBusyInstanceDoesNotCountTowardItsAccountsCoverage() {
        let plan = ScalePlan.make(
            input(
                records: [record("a", .busy, account: "work")],
                demand: ["work": [.tart: 1], "side": [.tart: 1]]))
        XCTAssertEqual(
            plan.slots.first?.account, "side", "work's busy VM covers nothing, so it ties side and the alphabet decides"
        )
        XCTAssertEqual(plan.slots.count, 2)
    }

    // MARK: - Scale down

    func testIdleSurplusIsDeletedOldestFirst() {
        let records = [record("new", .ready, age: 10), record("old", .ready, age: 0), record("busy", .busy)]
        let plan = ScalePlan.make(input(records: records, demand: [:]))
        XCTAssertEqual(plan.scaleDown, ["old", "new"])
    }

    func testMinRunnersKeepsWarmInstances() {
        var i = input(records: [record("a", .ready), record("b", .ready)], demand: [:])
        i.minRunners = 1
        XCTAssertEqual(ScalePlan.make(i).scaleDown.count, 1)
    }

    func testScaleDownSkipsAPoolThatStillHasQueuedJobs() {
        let records = [
            record("c1", .ready, runtime: .appleContainer, age: 0),
            record("t1", .ready, runtime: .tart, age: 1),
            record("t2", .busy, runtime: .tart),
            record("t3", .busy, runtime: .tart),
        ]
        let plan = ScalePlan.make(
            input(records: records, demand: ["github": [.appleContainer: 1]], pools: [.tart, .appleContainer]))
        XCTAssertEqual(plan.scaleDown, ["t1"], "the container VM serves the queued job; the idle tart one goes")
    }

    func testUnreadableQueueHoldsScaleDown() {
        var i = input(records: [record("a", .ready)], demand: [:])
        i.failedForges = ["github"]
        let plan = ScalePlan.make(i)
        XCTAssertTrue(plan.scaleDown.isEmpty)
        XCTAssertTrue(plan.scaleDownHeld)
    }

    // MARK: - Disk

    func testDiskAdmitsLeadingSlotsAndReportsTheFirstThatDoesNotFit() {
        let slots = (0..<3).map { _ in ScalePlan.Slot(account: "github", runtime: .tart) }
        let result = ScalePlan.admitByDisk(slots, freeDiskGB: 130, reserveGB: 20, diskPerInstanceGB: { _ in 50 })
        XCTAssertEqual(result.admitted.count, 2, "130 → 80 → 30 left, which is under 50 + 20")
        XCTAssertEqual(result.blocked?.availableGB, 30)
        XCTAssertEqual(result.blocked?.neededGB, 70)
    }

    func testHostSlotsCostNoDisk() {
        let slots = [
            ScalePlan.Slot(account: "github", runtime: .host), ScalePlan.Slot(account: "github", runtime: .tart),
        ]
        let result = ScalePlan.admitByDisk(slots, freeDiskGB: 10, reserveGB: 20, diskPerInstanceGB: { _ in 50 })
        XCTAssertEqual(result.admitted.map(\.runtime), [.host])
        XCTAssertNotNil(result.blocked)
    }
}
