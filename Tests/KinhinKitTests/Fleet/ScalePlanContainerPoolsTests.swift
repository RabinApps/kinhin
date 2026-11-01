import XCTest

@testable import KinhinKit

/// Named container pools in the scale plan (#75, step 2): per-pool demand and floors, and admission by each pool's
/// CPU and memory within the budget the pools share, on top of the runtime's count cap.
final class ScalePlanContainerPoolsTests: XCTestCase {
    private let epoch = Date(timeIntervalSince1970: 1_000_000)
    private let linuxFloor = ScalePlan.IdleKey(runtime: .appleContainer, pool: "linux")
    private let bigFloor = ScalePlan.IdleKey(runtime: .appleContainer, pool: "big")

    private func record(_ id: String, _ phase: VMPhase, pool: String?, age: TimeInterval = 0) -> VMRecord {
        var record = VMRecord(id: id, phase: phase, createdAt: epoch.addingTimeInterval(age))
        record.platform = "github"
        record.runtimeID = .appleContainer
        record.pool = pool
        return record
    }

    /// A fleet like the one in #75: an Apple container budget of 11 CPU / 43 GB, a small `linux` pool (2 CPU, 7 GB,
    /// the default) and a `big` one (4 CPU, 12 GB, at most 2). The count cap comes from the smallest shape, as
    /// `RuntimeCapacity.shape` makes it.
    private func input(
        records: [VMRecord] = [], pools: [String: Int] = [:], minIdle: [ScalePlan.IdleKey: Int] = [:],
        budget: RuntimeCapacity.Budget = .init(cpu: 11, memoryGB: 43), bigMax: Int? = 2, maxRunners: Int = 10
    ) -> ScalePlan.Input {
        let total = pools.values.reduce(0, +)
        var input = ScalePlan.Input(
            records: records, demand: total > 0 ? ["github": [.appleContainer: total]] : [:], attached: ["github"],
            maxRunners: maxRunners, capacityCap: maxRunners, existingPools: [.appleContainer],
            defaultRuntime: .appleContainer)
        input.poolCaps = [.appleContainer: budget.count(cpu: 2, memoryGB: 7)]
        input.containerPoolDemand = pools
        input.containerPools = [
            "linux": .init(cpus: 2, memoryGB: 7),
            "big": .init(cpus: 4, memoryGB: 12, max: bigMax),
        ]
        input.defaultContainerPool = "linux"
        input.containerBudget = budget
        input.minIdle = minIdle
        input.now = epoch.addingTimeInterval(60)
        return input
    }

    private func pools(_ slots: [ScalePlan.Slot]) -> [String] {
        slots.map { "\($0.pool ?? "-")\($0.idle ? " idle" : "")" }
    }

    // MARK: - Demand per pool

    func testEachPoolGetsSlotsForItsOwnJobs() {
        let plan = ScalePlan.make(input(pools: ["linux": 1, "big": 2]))
        XCTAssertEqual(pools(plan.slots), ["big", "big", "linux"], "the most unmet first, ties by name")
        XCTAssertEqual(Set(plan.slots.map(\.runtime)), [.appleContainer])
    }

    func testAnIdleRunnerOfOnePoolDoesNotServeAnotherPoolsJob() {
        let plan = ScalePlan.make(input(records: [record("l1", .ready, pool: "linux")], pools: ["big": 1]))
        XCTAssertEqual(pools(plan.slots), ["big"])
    }

    func testAnIdleRunnerOfThePoolServesItsJob() {
        let plan = ScalePlan.make(input(records: [record("b1", .ready, pool: "big")], pools: ["big": 1]))
        XCTAssertTrue(plan.slots.isEmpty)
    }

    func testARecordWithoutAKnownPoolCountsAsTheDefaultPool() {
        let plan = ScalePlan.make(input(records: [record("x", .ready, pool: nil)], pools: ["linux": 1]))
        XCTAssertTrue(plan.slots.isEmpty, "an adopted runner serves the default pool's job")
        let removed = ScalePlan.make(input(records: [record("x", .ready, pool: "gone")], pools: ["linux": 1]))
        XCTAssertTrue(removed.slots.isEmpty, "so does a runner of a pool since removed")
    }

    // MARK: - Admission by CPU and memory

    func testAPoolsMaxCapsItsInstances() {
        let plan = ScalePlan.make(input(pools: ["big": 5]))
        XCTAssertEqual(pools(plan.slots), ["big", "big"])
    }

    func testMixedShapesAreAdmittedByWhatIsLeftOfTheBudget() {
        // linux (3 jobs), big, linux take 8 CPU; a second big (4 CPU) no longer fits in 11, a third linux (2) does.
        let plan = ScalePlan.make(input(pools: ["linux": 3, "big": 2]))
        XCTAssertEqual(pools(plan.slots), ["linux", "big", "linux", "linux"])
        let running = [record("b1", .busy, pool: "big"), record("b2", .busy, pool: "big")]
        let busy = ScalePlan.make(input(records: running, pools: ["linux": 3]))
        XCTAssertEqual(pools(busy.slots), ["linux"], "busy big runners hold 8 of the 11 CPU")
    }

    func testTheBudgetBindsBeforeTheCountCap() {
        // Without a max, big is limited by memory: 43 GB hold 3 instances of 12 GB but 11 CPU only 2 of 4.
        let plan = ScalePlan.make(input(pools: ["big": 6], bigMax: nil))
        XCTAssertEqual(pools(plan.slots), ["big", "big"])
        XCTAssertEqual(plan.unmetByPool[.appleContainer], 6)
    }

    func testJobsOfAPoolThatCannotFitDoNotStartAnotherPool() {
        let plan = ScalePlan.make(input(pools: ["big": 1], budget: .init(cpu: 3, memoryGB: 43)))
        XCTAssertTrue(plan.slots.isEmpty, "a linux runner could not take big's job")
    }

    func testAFullRuntimeLeavesTheOtherRuntimesSlots() {
        var planInput = input(
            records: [record("b1", .busy, pool: "big"), record("b2", .busy, pool: "big")], pools: ["big": 1])
        planInput.existingPools = [.appleContainer, .tart]
        planInput.demand["github"]?[.tart] = 1
        let plan = ScalePlan.make(planInput)
        XCTAssertEqual(plan.slots.map(\.runtime), [.tart], "big is at its max, so the pass moves on to Tart")
    }

    func testAMinRunnersTopUpStartsTheDefaultPool() {
        var planInput = input()
        planInput.minRunners = 1
        XCTAssertEqual(pools(ScalePlan.make(planInput).slots), ["linux"])
    }

    // MARK: - Floors per pool

    func testEachPoolKeepsItsOwnFloor() {
        let plan = ScalePlan.make(input(minIdle: [linuxFloor: 1, bigFloor: 1]))
        XCTAssertEqual(pools(plan.slots), ["big idle", "linux idle"])
        let met = ScalePlan.make(
            input(records: [record("l1", .ready, pool: "linux")], minIdle: [linuxFloor: 1, bigFloor: 1]))
        XCTAssertEqual(pools(met.slots), ["big idle"], "linux's idle runner meets linux's floor only")
    }

    func testAFloorRespectsThePoolsMaxAndTheBudget() {
        let full = [record("b1", .busy, pool: "big"), record("b2", .busy, pool: "big")]
        XCTAssertTrue(ScalePlan.make(input(records: full, minIdle: [bigFloor: 1])).slots.isEmpty, "big is at its max")
        let tight = ScalePlan.make(input(minIdle: [bigFloor: 1], budget: .init(cpu: 3, memoryGB: 43)))
        XCTAssertTrue(tight.slots.isEmpty, "big's shape never fits")
    }

    func testAFloorsRunnerIsNotScaledDown() {
        let plan = ScalePlan.make(input(records: [record("l1", .ready, pool: "linux")], minIdle: [linuxFloor: 1]))
        XCTAssertTrue(plan.scaleDown.isEmpty)
        let surplus = ScalePlan.make(
            input(
                records: [record("l1", .ready, pool: "linux"), record("b1", .ready, pool: "big", age: 1)],
                minIdle: [linuxFloor: 1]))
        XCTAssertEqual(surplus.scaleDown, ["b1"], "only the runner beyond every floor goes")
    }

    func testAnIdleRunnerOfAnotherPoolMayGoWhileAJobWaits() {
        // big is at its max with its jobs; a linux job waits for room the idle big runner of nothing holds.
        let records = [record("b1", .ready, pool: "big"), record("l1", .busy, pool: "linux", age: 1)]
        let plan = ScalePlan.make(input(records: records, pools: ["linux": 1], budget: .init(cpu: 6, memoryGB: 43)))
        XCTAssertEqual(plan.scaleDown, ["b1"], "the idle big runner serves no waiting job and frees room for linux")
    }

    func testIdleKeysDescribeTheirPool() {
        XCTAssertEqual(bigFloor.description, "appleContainer/big")
        XCTAssertEqual(ScalePlan.IdleKey(runtime: .appleContainer).description, "appleContainer")
    }

    // MARK: - Without named pools

    func testWithoutNamedPoolsSlotsCarryNoPool() {
        var planInput = ScalePlan.Input(
            records: [], demand: ["github": [.appleContainer: 3]], attached: ["github"], maxRunners: 10,
            capacityCap: 10, existingPools: [.appleContainer], defaultRuntime: .appleContainer)
        planInput.poolCaps = [.appleContainer: 2]
        let plan = ScalePlan.make(planInput)
        XCTAssertEqual(plan.slots.count, 2, "the count cap alone sizes the unnamed pool")
        XCTAssertTrue(plan.slots.allSatisfy { $0.pool == nil })
    }
}
