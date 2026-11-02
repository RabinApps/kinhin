import XCTest

@testable import KinhinKit
@testable import KinhinTestSupport

/// How named container pools are sized (#75, step 2): the count caps come from the smallest pool shape (an upper
/// bound), the budget the pools share is the Apple container runtime's CPU and memory, and a section without
/// `pools:` keeps exactly the numbers it had.
final class ContainerPoolCapacityTests: XCTestCase {
    /// The Mac from #75: 16 cores and 64 GB with 0 CPU / 4 GB reserved leaves 16 CPU / 60 GB.
    private let host = HostResources(logicalCores: 16, memoryGB: 64, freeDiskGB: 900, arm64: true)

    private func config(pools: [KinhinConfig.ContainerConfig.Pool] = [], partitioned: Bool = false) -> KinhinConfig {
        var cfg = makeTestConfig()
        cfg.maxRunners = 10
        cfg.reserve = .init(cpu: 0, memoryGB: 4, diskGB: 10)
        cfg.vm.cpuCount = 2
        cfg.vm.memoryGB = 8
        cfg.container = .init(image: "kinhin-ci-linux", cpus: 2, memoryGB: 7, pools: pools)
        if partitioned {
            cfg.runtimes = .init(
                defaultRuntime: .appleContainer, budget: ["tart": 0.27, "appleContainer": 0.73], routes: [])
        }
        return cfg
    }

    private let linux = KinhinConfig.ContainerConfig.Pool(name: "linux", image: "i", cpus: 2, memoryGB: 7)
    private let big = KinhinConfig.ContainerConfig.Pool(name: "big", image: "i", cpus: 4, memoryGB: 12, max: 2)

    // MARK: - Without pools: unchanged

    func testASectionWithoutPoolsKeepsItsNumbers() {
        for partitioned in [false, true] {
            let cfg = config(partitioned: partitioned)
            XCTAssertNil(RuntimeCapacity.containerBudget(for: cfg, host: host), "no budget: the count caps suffice")
            XCTAssertEqual(RuntimeCapacity.shape(of: .appleContainer, in: cfg).cpu, 2)
            XCTAssertEqual(RuntimeCapacity.shape(of: .appleContainer, in: cfg).memoryGB, 7)
        }
        XCTAssertEqual(Capacity.plan(for: config(), host: host).maxConcurrent, 8, "60 GB / 7 GB, within max_runners")
        XCTAssertEqual(
            RuntimeCapacity.caps(for: config(partitioned: true), host: host)[.appleContainer], 6,
            "the default runtime's remainder, 12 CPU / 44 GB, holds 6 of 2 CPU / 7 GB")
    }

    func testOnePoolOfTheSectionsShapeGivesTheSameCaps() {
        let one = KinhinConfig.ContainerConfig.Pool(name: "linux", image: "i", cpus: 2, memoryGB: 7)
        for partitioned in [false, true] {
            XCTAssertEqual(
                RuntimeCapacity.caps(for: config(pools: [one], partitioned: partitioned), host: host),
                RuntimeCapacity.caps(for: config(partitioned: partitioned), host: host))
            XCTAssertEqual(
                Capacity.plan(for: config(pools: [one], partitioned: partitioned), host: host),
                Capacity.plan(for: config(partitioned: partitioned), host: host))
        }
    }

    func testTheSharedPartitionMathIsUnchanged() {
        // 16 × 0.73 = 11.68 → 11 CPU, 60 × 0.73 = 43.8 → 43 GB; Tart gets 16 × 0.27 = 4 CPU, 16 GB.
        let shares = RuntimeCapacity.shares(
            hostUsableCPU: 16, hostUsableMemoryGB: 60, weights: ["tart": 0.27, "appleContainer": 0.73],
            defaultRuntime: .appleContainer)
        XCTAssertEqual(shares[.tart], .init(cpu: 4, memoryGB: 16))
        XCTAssertEqual(shares[.appleContainer], .init(cpu: 12, memoryGB: 44), "the default runtime takes the rest")
        XCTAssertEqual(RuntimeCapacity.Budget(cpu: 11, memoryGB: 43).count(cpu: 2, memoryGB: 7), 5)
        XCTAssertEqual(RuntimeCapacity.Budget(cpu: 11, memoryGB: 43).count(cpu: 0, memoryGB: 7), 0)
    }

    // MARK: - With pools

    func testTheCountCapComesFromTheSmallestShape() {
        let cfg = config(pools: [linux, big])
        XCTAssertEqual(RuntimeCapacity.shape(of: .appleContainer, in: cfg).cpu, 2)
        XCTAssertEqual(RuntimeCapacity.shape(of: .appleContainer, in: cfg).memoryGB, 7)
        let mixed = config(pools: [
            .init(name: "cpu", image: "i", cpus: 1, memoryGB: 12), .init(name: "mem", image: "i", cpus: 6, memoryGB: 4),
        ])
        XCTAssertEqual(RuntimeCapacity.shape(of: .appleContainer, in: mixed).cpu, 1, "each resource's own minimum")
        XCTAssertEqual(RuntimeCapacity.shape(of: .appleContainer, in: mixed).memoryGB, 4)
    }

    func testThePoolsShareTheAppleContainerBudget() {
        XCTAssertEqual(
            RuntimeCapacity.containerBudget(for: config(pools: [linux, big]), host: host),
            .init(cpu: 16, memoryGB: 60), "a fleet without runtimes: gives the pools the host minus the reserve")
        XCTAssertEqual(
            RuntimeCapacity.containerBudget(for: config(pools: [linux, big], partitioned: true), host: host),
            .init(cpu: 12, memoryGB: 44), "a mixed fleet gives them Apple container's share")
    }

    func testAPoolsScaleSetOffersWhatItsShapeAndMaxAllow() {
        let snapshot = Router.Snapshot.make(config: config(pools: [linux, big], partitioned: true), host: host)
        XCTAssertEqual(
            snapshot.jobCapacity(forContainerPool: big, maxRunners: 10, capacityCap: 10, runnersPerVM: 1), 2,
            "its max")
        XCTAssertEqual(
            snapshot.jobCapacity(forContainerPool: linux, maxRunners: 10, capacityCap: 10, runnersPerVM: 1), 6,
            "12 CPU / 44 GB hold 6 linux runners")
        var unbounded = big
        unbounded.max = nil
        XCTAssertEqual(
            snapshot.jobCapacity(forContainerPool: unbounded, maxRunners: 10, capacityCap: 10, runnersPerVM: 2), 6,
            "3 big runners (12 CPU), two jobs each")
    }

    func testAPoolLargerThanTheBudgetNeverFits() {
        var huge = big
        huge.cpus = 32
        let snapshot = Router.Snapshot.make(config: config(pools: [linux, huge]), host: host)
        XCTAssertEqual(snapshot.containerBudget?.count(cpu: huge.cpus, memoryGB: huge.memoryGB), 0)
        XCTAssertEqual(snapshot.containerBudget?.count(cpu: linux.cpus, memoryGB: linux.memoryGB), 8)
    }
}
