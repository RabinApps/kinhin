import XCTest

@testable import KinhinKit

/// `min_idle`: the scale plan keeps a floor of registered, idle runners per pool and per Tart image (#73).
final class ScalePlanMinIdleTests: XCTestCase {
    private let epoch = Date(timeIntervalSince1970: 1_000_000)
    private let macos = ScalePlan.IdleKey(runtime: .tart, image: "macos-27")
    private let xcode = ScalePlan.IdleKey(runtime: .tart, image: "xcode")
    private let linux = ScalePlan.IdleKey(runtime: .appleContainer)

    private func record(
        _ id: String, _ phase: VMPhase, runtime: RuntimeID = .tart, image: String? = nil, age: TimeInterval = 0
    ) -> VMRecord {
        var record = VMRecord(id: id, phase: phase, createdAt: epoch.addingTimeInterval(age))
        record.platform = phase == .warm ? nil : "github"
        record.runtime = runtime.rawValue
        record.image = image
        return record
    }

    /// A mixed fleet like the one in #73: Tart (cap 2) and Apple container (cap 6) under max_runners 10, with
    /// Apple container as the default runtime.
    private func input(
        records: [VMRecord] = [], demand: [RuntimeID: Int] = [:], imageDemand: [String: Int] = [:],
        minIdle: [ScalePlan.IdleKey: Int] = [:], maxRunners: Int = 10
    ) -> ScalePlan.Input {
        var input = ScalePlan.Input(
            records: records, demand: demand.isEmpty ? [:] : ["github": demand], attached: ["github"],
            maxRunners: maxRunners, capacityCap: maxRunners, existingPools: [.tart, .appleContainer],
            defaultRuntime: .appleContainer)
        input.poolCaps = [.tart: 2, .appleContainer: 6]
        input.imageDemand = imageDemand
        input.minIdle = minIdle
        input.now = epoch.addingTimeInterval(60)
        return input
    }

    private func described(_ slots: [ScalePlan.Slot]) -> [String] {
        slots.map { "\($0.runtime.rawValue)/\($0.image ?? "")\($0.idle ? " idle" : "")" }
    }

    // MARK: - Off by default

    func testZeroFloorsChangeNothing() {
        let busy = record("b1", .busy, image: "macos-27")
        let ready = record("r1", .ready, runtime: .appleContainer)
        let cases = [
            input(),
            input(records: [busy, ready]),
            input(records: [busy], demand: [.tart: 2, .appleContainer: 1], imageDemand: ["xcode": 1]),
            input(records: [ready, record("r2", .ready, runtime: .appleContainer, age: 1)]),
        ]
        for var planInput in cases {
            let without = ScalePlan.make(planInput)
            planInput.minIdle = [macos: 0, xcode: 0, linux: 0]
            XCTAssertEqual(ScalePlan.make(planInput), without)
        }
    }

    // MARK: - Top-ups with an empty queue

    func testIdleFleetStartsOneRunnerPerFloorWithNothingQueued() {
        let plan = ScalePlan.make(input(minIdle: [macos: 1, xcode: 1, linux: 1]))
        XCTAssertEqual(
            described(plan.slots), ["appleContainer/ idle", "tart/macos-27 idle", "tart/xcode idle"])
        XCTAssertEqual(Set(plan.slots.map(\.account)), ["github"])
        XCTAssertEqual(plan.target, 3)
        XCTAssertEqual(plan.desired, 0, "desired still reports the queue and min_runners")
    }

    func testAnIdleRegisteredRunnerMeetsItsFloor() {
        let plan = ScalePlan.make(input(records: [record("m1", .ready, image: "macos-27")], minIdle: [macos: 1]))
        XCTAssertTrue(plan.slots.isEmpty)
        XCTAssertTrue(plan.scaleDown.isEmpty, "the floor's runner is not idle surplus")
    }

    func testAStartingRunnerCountsTowardItsFloor() {
        for phase in [VMPhase.cloning, .booting, .registering] {
            let plan = ScalePlan.make(input(records: [record("m1", phase, image: "macos-27")], minIdle: [macos: 1]))
            XCTAssertTrue(plan.slots.isEmpty, "\(phase) is on its way to idle")
        }
    }

    func testAnotherImagesRunnerDoesNotCount() {
        let plan = ScalePlan.make(input(records: [record("x1", .ready, image: "xcode")], minIdle: [macos: 1]))
        XCTAssertEqual(described(plan.slots), ["tart/macos-27 idle"])
    }

    func testAWarmVMIsClaimedForATopUpInsteadOfCloning() {
        var planInput = input(records: [record("w1", .warm, image: "macos-27")], minIdle: [macos: 1])
        planInput.warmPool = ["macos-27": 1]
        let plan = ScalePlan.make(planInput)
        XCTAssertEqual(plan.claims, ["w1"], "registering the warm VM is the quickest idle runner")
        XCTAssertTrue(plan.slots.allSatisfy(\.idle))
        XCTAssertEqual(plan.warmSpawn, [:], "the warm pool refills on a later pass, when nothing else needs slots")
    }

    // MARK: - Busy runners

    func testABusyRunnerIsReplacedAtOnce() {
        let plan = ScalePlan.make(input(records: [record("m1", .busy, image: "macos-27")], minIdle: [macos: 1]))
        XCTAssertEqual(described(plan.slots), ["tart/macos-27 idle"])
    }

    func testABusyLinuxRunnerIsReplacedAtOnce() {
        let plan = ScalePlan.make(input(records: [record("c1", .busy, runtime: .appleContainer)], minIdle: [linux: 1]))
        XCTAssertEqual(described(plan.slots), ["appleContainer/ idle"])
    }

    func testAScaleSetBusyRunnerCoversOnlyItsOwnJob() {
        // A scale-set queue counts the running job too, and the busy runner covers it: one replacement, not two.
        var planInput = input(
            records: [record("m1", .busy, image: "macos-27")], demand: [.tart: 1], imageDemand: ["macos-27": 1],
            minIdle: [macos: 1])
        planInput.includesRunning = ["github"]
        XCTAssertEqual(described(ScalePlan.make(planInput).slots), ["tart/macos-27 idle"])
    }

    // MARK: - Caps and holds

    func testTopUpsStopAtThePoolCap() {
        // One busy macOS VM leaves one of Tart's two slots: the first key in order takes it.
        let plan = ScalePlan.make(
            input(records: [record("m1", .busy, image: "macos-27")], minIdle: [macos: 1, xcode: 1]))
        XCTAssertEqual(described(plan.slots), ["tart/macos-27 idle"])
    }

    func testTopUpsStopAtTheGlobalCapAndTakeTurns() {
        let plan = ScalePlan.make(input(minIdle: [linux: 2, macos: 2], maxRunners: 2))
        XCTAssertEqual(described(plan.slots), ["appleContainer/ idle", "tart/macos-27 idle"], "one per key per round")
    }

    func testAHeldRuntimeGetsNoTopUp() {
        var planInput = input(minIdle: [macos: 1, linux: 1])
        planInput.heldRuntimes = [.tart]
        XCTAssertEqual(described(ScalePlan.make(planInput).slots), ["appleContainer/ idle"])
    }

    func testAPoolThatIsNotConfiguredGetsNoTopUp() {
        var planInput = input(minIdle: [ScalePlan.IdleKey(runtime: .docker): 1])
        planInput.existingPools = [.tart]
        XCTAssertTrue(ScalePlan.make(planInput).slots.isEmpty)
    }

    func testNothingStartsWithNoForgeAttached() {
        var planInput = input(minIdle: [linux: 1])
        planInput.attached = []
        XCTAssertTrue(ScalePlan.make(planInput).slots.isEmpty)
    }

    func testInFlightPooledClonesKeepTheirRoom() {
        // A pooled clone still booting holds one of Tart's two slots, and a busy runner the other.
        var pooled = record("p1", .cloning, image: "xcode")
        pooled.pooled = true
        pooled.platform = nil
        let plan = ScalePlan.make(
            input(records: [record("m1", .busy, image: "macos-27"), pooled], minIdle: [macos: 1]))
        XCTAssertTrue(plan.slots.isEmpty)
    }

    // MARK: - Queued demand first

    func testQueuedDemandWinsWhenSlotsAreScarce() {
        let plan = ScalePlan.make(input(demand: [.appleContainer: 2], minIdle: [macos: 1], maxRunners: 2))
        XCTAssertEqual(described(plan.slots), ["appleContainer/", "appleContainer/"])
    }

    func testAQueuedJobDoesNotFillTheFloor() {
        // The new instance is the queued job's; the floor needs one more beside it.
        let plan = ScalePlan.make(input(demand: [.appleContainer: 1], minIdle: [linux: 1]))
        XCTAssertEqual(described(plan.slots), ["appleContainer/", "appleContainer/ idle"])
    }

    func testAMinRunnersInstanceCountsTowardTheDefaultPoolsFloor() {
        var planInput = input(minIdle: [linux: 1])
        planInput.minRunners = 1
        XCTAssertEqual(described(ScalePlan.make(planInput).slots), ["appleContainer/"])
    }

    func testAnImagesJobTakesTheSlotBeforeAnotherImagesTopUp() {
        let plan = ScalePlan.make(
            input(demand: [.tart: 1], imageDemand: ["xcode": 1], minIdle: [macos: 1, xcode: 1]))
        XCTAssertEqual(described(plan.slots), ["tart/xcode", "tart/macos-27 idle"], "Tart's two slots, the job first")
    }

    // MARK: - Per-image demand with a Tart floor

    func testAnIdleRunnerOfOneImageDoesNotHideAnotherImagesJob() {
        let plan = ScalePlan.make(
            input(
                records: [record("m1", .ready, image: "macos-27")], demand: [.tart: 1], imageDemand: ["xcode": 1],
                minIdle: [macos: 1]))
        XCTAssertEqual(described(plan.slots), ["tart/xcode"], "the idle macOS runner cannot take an Xcode job")
    }

    func testABusyRunnerDoesNotSteerTheNextSlotToAnotherImage() {
        var planInput = input(
            records: [record("m1", .busy, image: "macos-27")], demand: [.tart: 1], imageDemand: ["macos-27": 1],
            minIdle: [macos: 1])
        planInput.poolCaps[.tart] = 3
        XCTAssertEqual(described(ScalePlan.make(planInput).slots), ["tart/macos-27", "tart/macos-27 idle"])
    }

    // MARK: - Scale-down

    func testScaleDownKeepsTheFloorAndRemovesTheSurplus() {
        let records = [
            record("m1", .ready, image: "macos-27"), record("m2", .ready, image: "macos-27", age: 1),
            record("c1", .ready, runtime: .appleContainer, age: 2),
        ]
        let plan = ScalePlan.make(input(records: records, minIdle: [macos: 1]))
        XCTAssertEqual(plan.scaleDown, ["m1", "c1"], "one macOS runner stays as the floor")
    }

    func testAnIdleSurplusRunnerMakesWayForAnotherImagesJob() {
        // Tart is full with the macOS floor's runner and a surplus base runner while an Xcode job waits: the
        // surplus runner goes, freeing its slot for the job on the next pass; the floor's runner stays.
        let records = [record("m1", .ready, image: "macos-27"), record("b1", .ready, age: 1)]
        let plan = ScalePlan.make(
            input(records: records, demand: [.tart: 1], imageDemand: ["xcode": 1], minIdle: [macos: 1]))
        XCTAssertTrue(plan.slots.isEmpty, "Tart's partition is full this pass")
        XCTAssertEqual(plan.scaleDown, ["b1"])
    }

    func testAFloorsRunnerIsNotRetiredForAnotherImagesJob() {
        // Both Tart slots hold floor runners and a job for the base image waits: it gets a slot only once one of
        // them picks up a job of its own and finishes (#73's trade-off; documented in docs/scaling.md).
        let records = [record("m1", .ready, image: "macos-27"), record("x1", .ready, image: "xcode", age: 1)]
        let plan = ScalePlan.make(input(records: records, demand: [.tart: 1], minIdle: [macos: 1, xcode: 1]))
        XCTAssertTrue(plan.slots.isEmpty, "Tart's partition is full")
        XCTAssertTrue(plan.scaleDown.isEmpty, "a floor's runner is never retired for another image's job")
    }
}
