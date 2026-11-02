import XCTest

@testable import KinhinKit
@testable import KinhinTestSupport

/// Named container pools (#75, step 2): which pool a container job lands in, the labels each pool's runners register
/// with, and the tables (router, scale sets, `kinhin workflow route`) that read them. A section without `pools:`
/// keeps exactly the labels and routing it had.
final class ContainerPoolRoutingTests: XCTestCase {
    private static func pooledConfig(runtimes: KinhinConfig.RuntimeConfig? = nil) -> KinhinConfig {
        var cfg = makeTestConfig()
        cfg.labels = ["self-hosted", "arm64", "macos"]
        cfg.container = .init(
            image: "kinhin-ci-linux", cpus: 2, memoryGB: 7,
            pools: [
                .init(name: "big", image: "kinhin-ci-linux", cpus: 4, memoryGB: 12, labels: ["linux", "big"], max: 2),
                .init(name: "linux", image: "kinhin-ci-linux", cpus: 2, memoryGB: 7, labels: ["linux"], minIdle: 1),
            ])
        cfg.runtimes = runtimes
        return cfg
    }

    private static func job(_ labels: [String], hint: RuntimeID? = nil) -> ForgeJob {
        ForgeJob(name: "ci / build", runnerName: nil, repository: "acme/widgets", labels: labels, runtimeHint: hint)
    }

    private func engine(_ config: KinhinConfig) -> FleetEngine {
        FleetEngine(
            config: config, github: FakeGitHub(), tart: FakeTart(), store: makeTestStore(), ssh: FakeSSH(),
            host: testHost, dependencies: .init(tokenLoader: { _, _ in "t" }, exitWatchInterval: .milliseconds(20)))
    }

    private static func containerRecord(pool: String?) -> VMRecord {
        var record = VMRecord(id: "kinhin-1700000000-0000abcd", phase: .cloning)
        record.runtimeID = .appleContainer
        record.pool = pool
        return record
    }

    // MARK: - The table

    func testEachPoolRegistersItsLabelsTheMarkerAndItsOwnMarker() {
        let table = RuntimeConfigModel(config: Self.pooledConfig()).containerPools
        XCTAssertEqual(table.entries.map(\.name), ["big", "linux"])
        XCTAssertEqual(
            table.entry(named: "big")?.labels,
            ["self-hosted", "arm64", "linux", "big", "kinhin-container", "kinhin-container-big"],
            "the fleet labels without macos, the pool's own, then both markers")
        XCTAssertEqual(
            table.entry(named: "linux")?.labels,
            ["self-hosted", "arm64", "linux", "kinhin-container", "kinhin-container-linux"])
        XCTAssertEqual(table.defaultName, "linux")
        XCTAssertEqual(table.entry(named: nil)?.name, "linux", "an instance without a pool runs as the default one")
        XCTAssertEqual(table.entry(named: "gone")?.name, "linux")
    }

    func testFleetLabelsFalseOnAPoolReplacesTheFleetLabelsInAMixedFleet() {
        var cfg = Self.pooledConfig(runtimes: .init(defaultRuntime: .tart, budget: [:], routes: []))
        cfg.container?.pools[0].fleetLabels = false
        XCTAssertEqual(
            RuntimeConfigModel(config: cfg).containerPools.entry(named: "big")?.labels,
            ["linux", "big", "kinhin-container", "kinhin-container-big"])
        cfg.runtimes = nil
        XCTAssertEqual(
            RuntimeConfigModel(config: cfg).containerPools.entry(named: "big")?.labels,
            ["self-hosted", "arm64", "linux", "big", "kinhin-container", "kinhin-container-big"],
            "a fleet without runtimes: keeps the fleet labels on its one runtime, as the section always did")
    }

    func testASectionWithoutPoolsHasNoTableAndKeepsItsLabels() {
        var cfg = Self.pooledConfig()
        cfg.container?.pools = []
        cfg.container?.labels = ["linux"]
        let model = RuntimeConfigModel(config: cfg)
        XCTAssertTrue(model.containerPools.isEmpty)
        XCTAssertEqual(model.pools[.appleContainer]?.labels, ["self-hosted", "arm64", "linux", "kinhin-container"])
        XCTAssertEqual(model.demandByContainerPool(for: [Self.job(["linux"])]), [:])
        let snapshot = Router.Snapshot.make(config: cfg, host: testHost)
        XCTAssertFalse(snapshot.servedLabels.contains { $0.hasPrefix("kinhin-container-") })
        XCTAssertEqual(
            engine(cfg).poolLabels(for: Self.containerRecord(pool: nil)),
            ["self-hosted", "arm64", "linux", "kinhin-container"], "registration labels exactly as before pools")
    }

    func testNoAppleContainerPoolMeansNoTable() {
        var cfg = Self.pooledConfig(runtimes: .init(defaultRuntime: .tart, budget: [:], routes: []))
        XCTAssertFalse(RuntimeConfigModel(config: cfg).containerPools.isEmpty)
        cfg.container = nil
        XCTAssertTrue(RuntimeConfigModel(config: cfg).containerPools.isEmpty)
    }

    // MARK: - Which pool serves a job

    func testTheMostSpecificPoolWins() {
        let table = RuntimeConfigModel(config: Self.pooledConfig()).containerPools
        XCTAssertEqual(table.pool(for: ["self-hosted", "arm64", "linux"])?.name, "linux")
        XCTAssertEqual(table.pool(for: ["self-hosted", "arm64", "linux", "big"])?.name, "big")
        XCTAssertEqual(table.pool(for: ["self-hosted", "ARM64", "LINUX", "Big"])?.name, "big", "labels ignore case")
    }

    func testAJobNoPoolClaimsGoesToTheDefaultPool() {
        let table = RuntimeConfigModel(config: Self.pooledConfig()).containerPools
        XCTAssertEqual(table.pool(for: ["self-hosted", "arm64"])?.name, "linux")
        XCTAssertEqual(table.pool(for: ["self-hosted", "arm64", "big"])?.name, "linux", "big alone is not enough")
        XCTAssertEqual(table.pool(for: nil)?.name, "linux")
    }

    func testAPoolsMarkerTargetsItWhateverElseTheJobCarries() {
        let table = RuntimeConfigModel(config: Self.pooledConfig()).containerPools
        XCTAssertEqual(table.pool(for: ["self-hosted", "kinhin-container-big"])?.name, "big")
        XCTAssertEqual(table.pool(for: ["linux", "big", "kinhin-container-linux"])?.name, "linux")
        XCTAssertEqual(table.pool(for: ["KINHIN-CONTAINER-BIG"])?.name, "big")
        XCTAssertNil(table.explicitPool(for: ["kinhin-container"]), "the runtime marker names no pool")
    }

    func testAPoolsMarkerRoutesToAppleContainerWithoutARoute() {
        let model = RuntimeConfigModel(
            config: Self.pooledConfig(runtimes: .init(defaultRuntime: .tart, budget: [:], routes: [])))
        XCTAssertEqual(model.runtime(for: Self.job(["self-hosted", "arm64"])), .tart)
        XCTAssertEqual(model.runtime(for: Self.job(["self-hosted", "arm64", "kinhin-container-big"])), .appleContainer)
        XCTAssertEqual(model.runtime(for: Self.job(["self-hosted", "arm64", "kinhin-container"])), .appleContainer)
        XCTAssertEqual(
            model.runtime(for: Self.job(["self-hosted", "arm64", "linux"])), .tart,
            "a pool's own labels pick a pool within Apple container, like an image's within Tart, not the runtime")
    }

    func testDemandIsCountedPerPool() {
        let model = RuntimeConfigModel(config: Self.pooledConfig())
        let jobs = [
            Self.job(["self-hosted", "arm64", "linux"]),
            Self.job(["self-hosted", "arm64", "linux", "big"]),
            Self.job(["self-hosted", "arm64", "linux", "big"]),
            Self.job(["self-hosted", "arm64"]),
            Self.job(["kinhin-container-big"], hint: .appleContainer),
        ]
        XCTAssertEqual(model.demandByContainerPool(for: jobs), ["linux": 2, "big": 3])
        XCTAssertEqual(model.demandByPool(for: jobs, forgeID: .github), [.appleContainer: 5])
    }

    func testTartJobsCountForNoContainerPool() {
        let model = RuntimeConfigModel(
            config: Self.pooledConfig(runtimes: .init(defaultRuntime: .tart, budget: [:], routes: [])))
        XCTAssertEqual(
            model.demandByContainerPool(for: [Self.job(["linux"]), Self.job(["linux", "kinhin-container"])]),
            ["linux": 1])
    }

    // MARK: - The engine's tables

    func testRunnersRegisterWithTheirPoolsLabels() {
        let engine = engine(Self.pooledConfig())
        XCTAssertEqual(
            engine.poolLabels(for: Self.containerRecord(pool: "big")),
            ["self-hosted", "arm64", "linux", "big", "kinhin-container", "kinhin-container-big"])
        XCTAssertEqual(
            engine.poolLabels(for: Self.containerRecord(pool: nil)),
            ["self-hosted", "arm64", "linux", "kinhin-container", "kinhin-container-linux"],
            "an adopted instance registers as the default pool")
    }

    func testServedLabelsIncludeEveryPoolsLabels() {
        let served = Set(Router.Snapshot.make(config: Self.pooledConfig(), host: testHost).servedLabels)
        XCTAssertTrue(
            served.isSuperset(of: [
                "linux", "big", "kinhin-container", "kinhin-container-big", "kinhin-container-linux",
            ]),
            "\(served)")
    }

    func testEachPoolGetsItsOwnScaleSet() {
        let engine = engine(Self.pooledConfig())
        let plan = engine.scaleSetPlan(
            account: AccountConfig(name: "s", forge: .github, scope: "acme", scaleSet: .init(name: "kinhin")),
            baseName: "kinhin")
        XCTAssertEqual(plan.map(\.name), ["kinhin", "kinhin-container-big", "kinhin-container-linux"])
        XCTAssertEqual(plan.map(\.runtime), [.appleContainer, .appleContainer, .appleContainer])
        XCTAssertEqual(plan[0].labels, RuntimeConfigModel.poolLabels(for: .appleContainer, config: Self.pooledConfig()))
        XCTAssertEqual(
            plan[1].labels, RuntimeConfigModel.containerPoolLabels(named: "big", config: Self.pooledConfig()))
    }

    func testAMixedFleetNamesThePoolSetsAfterTheContainerSet() {
        let engine = engine(Self.pooledConfig(runtimes: .init(defaultRuntime: .tart, budget: [:], routes: [])))
        let plan = engine.scaleSetPlan(
            account: AccountConfig(name: "s", forge: .github, scope: "acme", scaleSet: .init(name: "ci")),
            baseName: "ci")
        XCTAssertEqual(plan.map(\.name), ["ci", "ci-container", "ci-container-big", "ci-container-linux"])
    }

    func testTheCLIReadsTheEnginesPoolLabels() {
        let cfg = Self.pooledConfig()
        XCTAssertEqual(
            RuntimeConfigModel.containerPoolLabels(named: "linux", config: cfg),
            engine(cfg).poolLabels(for: Self.containerRecord(pool: "linux")))
        XCTAssertNil(RuntimeConfigModel.containerPoolLabels(named: "nope", config: cfg))
    }

    // MARK: - kinhin workflow route --pool

    func testRoutingToAPoolAddsItsMarker() {
        let labels = RuntimeConfigModel.containerPoolLabels(named: "big", config: Self.pooledConfig()) ?? []
        XCTAssertEqual(
            WorkflowRouteEditor.editJobLabels(
                current: ["self-hosted", "arm64"], runtime: .appleContainer, poolLabels: labels,
                poolMarker: "kinhin-container-big"),
            ["self-hosted", "arm64", "kinhin-container", "kinhin-container-big"])
        XCTAssertEqual(
            WorkflowRouteEditor.editJobLabels(
                current: ["ubuntu-latest"], runtime: .appleContainer, poolLabels: labels,
                poolMarker: "kinhin-container-big"),
            labels, "nothing matchable: the pool's exact labels, its marker included")
        XCTAssertEqual(
            WorkflowRouteEditor.editJobLabels(
                current: ["self-hosted", "kinhin-container-big"], runtime: .appleContainer, poolLabels: labels,
                poolMarker: "kinhin-container-big"),
            ["self-hosted", "kinhin-container-big", "kinhin-container"], "an existing marker is not repeated")
    }
}
