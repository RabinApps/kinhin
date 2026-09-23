import XCTest
@testable import OrchardKit

/// Stage 2 routing: label pools, job→pool assignment (workflow route →
/// repo route → label opt-in → default), the weighted capacity partition,
/// config parsing/validation, and the engine spawning per-runtime instances
/// from bucketed demand.
final class RuntimeRoutingTests: XCTestCase {
    // MARK: - Fixtures

    private let fleetLabels = ["self-hosted", "macos", "arm64"]

    private func mixedRoutes() -> [OrchardConfig.RuntimeConfig.Route] {
        [
            OrchardConfig.RuntimeConfig.Route(pattern: "acme/ios-app", runtime: "tart"),
            OrchardConfig.RuntimeConfig.Route(pattern: "acme/api", runtime: "appleContainer"),
            OrchardConfig.RuntimeConfig.Route(pattern: "acme/web@Linux-only checks", runtime: "appleContainer"),
        ]
    }

    private func mixedConfig(defaultRuntime: String = "tart", budget: [String: Double] = ["tart": 0.6, "appleContainer": 0.4]) -> OrchardConfig.RuntimeConfig {
        OrchardConfig.RuntimeConfig(defaultRuntime: defaultRuntime, budget: budget, routes: mixedRoutes())
    }

    private func dockerConfig() -> OrchardConfig {
        var cfg = makeTestConfig()
        cfg.repo = "acme"
        cfg.docker = .init(image: "ghcr.io/acme/orchard-ci-linux", cpus: 2, memoryGB: 4, maxSlots: 8)
        cfg.runtimes = OrchardConfig.RuntimeConfig(
            defaultRuntime: "tart",
            budget: ["tart": 0.5, "docker": 0.5],
            routes: [OrchardConfig.RuntimeConfig.Route(pattern: "acme/api", runtime: "docker")]
        )
        return cfg
    }

    private func jobs(_ defs: [(repo: String?, name: String, labels: [String]?)]) -> [ForgeJob] {
        defs.map { ForgeJob(name: $0.name, runnerName: nil, repository: $0.repo, labels: $0.labels) }
    }

    // MARK: - Pool construction

    func testSinglePoolWhenNoRoutingConfig() {
        let model = RuntimeConfigModel(config: nil, fleetLabels: fleetLabels, containerConfigured: false)
        XCTAssertEqual(model.pools.count, 1)
        XCTAssertEqual(model.defaultRuntime, .tart)
        XCTAssertNil(model.pools[.appleContainer])
    }

    func testSingleContainerPoolWhenContainerConfiguredWithoutRouting() {
        let model = RuntimeConfigModel(config: nil, fleetLabels: fleetLabels, containerConfigured: true)
        XCTAssertEqual(model.pools.count, 1, "no runtimes: section → the fleet stays single-pool (pre-routing behavior)")
        XCTAssertEqual(model.defaultRuntime, .appleContainer)
        XCTAssertTrue(model.pools[.appleContainer]?.labels.contains("orchard-container") ?? false)
    }

    func testMixedPoolsWhenRoutingConfigPresent() {
        let model = RuntimeConfigModel(config: mixedConfig(), fleetLabels: fleetLabels, containerConfigured: true)
        XCTAssertEqual(Set(model.pools.keys), [.tart, .appleContainer])
        XCTAssertEqual(model.pools[.tart]?.labels, fleetLabels, "tart pool keeps the fleet labels (macOS default pool)")
        XCTAssertTrue(model.pools[.appleContainer]?.labels.contains("orchard-container") ?? false)
        XCTAssertTrue(model.pools[.appleContainer]?.labels.contains("self-hosted") ?? false)
    }

    // MARK: - Job → pool assignment

    private func router() -> (RuntimeConfigModel, RuntimePool, [RuntimeID: RuntimePool]) {
        let model = RuntimeConfigModel(config: mixedConfig(), fleetLabels: fleetLabels, containerConfigured: true)
        let defaultPool = model.pools[.tart]!
        return (model, defaultPool, model.pools)
    }

    func testRepoRoutePicksConfiguredRuntime() {
        let (model, defaultPool, pools) = router()
        let job = ForgeJob(name: "build", runnerName: nil, repository: "acme/ios-app", labels: nil)
        let decision = RuntimeRouter.assign(job: job, config: model, defaultPool: defaultPool, pools: pools)
        XCTAssertEqual(decision.pool.runtime, .tart)
        XCTAssertEqual(decision.via, "repo:acme/ios-app")
    }

    func testContainerRepoRoutePicksContainerPool() {
        let (model, defaultPool, pools) = router()
        let job = ForgeJob(name: "build", runnerName: nil, repository: "acme/api", labels: nil)
        let decision = RuntimeRouter.assign(job: job, config: model, defaultPool: defaultPool, pools: pools)
        XCTAssertEqual(decision.pool.runtime, .appleContainer)
        XCTAssertEqual(decision.via, "repo:acme/api")
    }

    func testWorkflowRouteOverridesRepoRoute() {
        let (model, defaultPool, pools) = router()
        // acme/web has no repo route, but its "Linux-only checks" workflow does.
        let job = ForgeJob(name: "Linux-only checks / lint", runnerName: nil, repository: "acme/web", labels: nil)
        let decision = RuntimeRouter.assign(job: job, config: model, defaultPool: defaultPool, pools: pools)
        XCTAssertEqual(decision.pool.runtime, .appleContainer)
        XCTAssertTrue(decision.via.hasPrefix("workflow:"), decision.via)
        // The same repo's other jobs fall to the default.
        let other = ForgeJob(name: "web tests / unit", runnerName: nil, repository: "acme/web", labels: nil)
        let fallback = RuntimeRouter.assign(job: other, config: model, defaultPool: defaultPool, pools: pools)
        XCTAssertEqual(fallback.pool.runtime, .tart)
        XCTAssertEqual(fallback.via, "default")
    }

    func testLabelOptInRoutesToContainerPool() {
        let (model, defaultPool, pools) = router()
        // No repo route for acme/web; the workflow opts in via runs-on.
        let job = ForgeJob(name: "lint", runnerName: nil, repository: "acme/web", labels: ["orchard-container"])
        let decision = RuntimeRouter.assign(job: job, config: model, defaultPool: defaultPool, pools: pools)
        XCTAssertEqual(decision.pool.runtime, .appleContainer)
        XCTAssertEqual(decision.via, "label:orchard-container")
    }

    // MARK: - Docker pool

    private func dockerRouter() -> (RuntimeConfigModel, RuntimePool, [RuntimeID: RuntimePool]) {
        let model = RuntimeConfigModel(
            config: dockerConfig().runtimes,
            fleetLabels: fleetLabels,
            containerConfigured: false,
            dockerConfigured: true
        )
        let defaultPool = model.pools[.tart]!
        return (model, defaultPool, model.pools)
    }

    func testDockerPoolJoinsRoutingWhenConfigured() {
        let (model, _, pools) = dockerRouter()
        XCTAssertEqual(Set(model.pools.keys), [.tart, .docker])
        XCTAssertTrue(model.pools[.docker]?.labels.contains("orchard-docker") ?? false)
        XCTAssertTrue(model.pools[.docker]?.labels.contains("self-hosted") ?? false)
        _ = pools
    }

    func testDockerRepoRoutePicksDockerPool() {
        let (model, defaultPool, pools) = dockerRouter()
        let job = ForgeJob(name: "build", runnerName: nil, repository: "acme/api", labels: nil)
        let decision = RuntimeRouter.assign(job: job, config: model, defaultPool: defaultPool, pools: pools)
        XCTAssertEqual(decision.pool.runtime, .docker)
        XCTAssertEqual(decision.via, "repo:acme/api")
    }

    func testDockerLabelOptInRoutesToDockerPool() {
        let (model, defaultPool, pools) = dockerRouter()
        let job = ForgeJob(name: "lint", runnerName: nil, repository: "acme/other", labels: ["orchard-docker"])
        let decision = RuntimeRouter.assign(job: job, config: model, defaultPool: defaultPool, pools: pools)
        XCTAssertEqual(decision.pool.runtime, .docker)
        XCTAssertEqual(decision.via, "label:orchard-docker")
    }

    func testDockerPartitionRespectsMaxSlots() {
        // Weighted partition gives docker its share; the docker.max_slots
        // cap then clamps it (engine-side min()).
        let partition = RuntimeCapacity.partition(
            hostUsableCPU: 10, hostUsableMemoryGB: 28,
            weights: ["tart": 0.5, "docker": 0.5],
            defaultRuntime: .tart,
            shape: { $0 == .docker ? (2, 4) : (4, 8) }
        )
        XCTAssertEqual(partition.caps[.docker], 2, "5 CPU/14 GB → 2×(2 CPU, 4 GB)")
        XCTAssertEqual(partition.caps[.tart], 1)
    }

    func testSingleDockerPoolWhenOnlyDockerConfigured() {
        // Docker without any runtimes: section and without tart images →
        // the fleet's primary runtime becomes docker (engine precedence).
        let model = RuntimeConfigModel(
            config: nil,
            fleetLabels: fleetLabels,
            containerConfigured: false,
            dockerConfigured: true
        )
        XCTAssertEqual(model.defaultRuntime, .docker)
        XCTAssertEqual(model.pools.count, 1)
        XCTAssertTrue(model.pools[.docker]?.labels.contains("orchard-docker") ?? false)
    }

    func testUnroutedJobFallsToDefaultPool() {
        let (model, defaultPool, pools) = router()
        let job = ForgeJob(name: "misc", runnerName: nil, repository: "acme/other", labels: nil)
        let decision = RuntimeRouter.assign(job: job, config: model, defaultPool: defaultPool, pools: pools)
        XCTAssertEqual(decision.pool.runtime, .tart)
        XCTAssertEqual(decision.via, "default")
    }

    func testWorkflowNameMatchingIsCaseInsensitive() {
        let (model, defaultPool, pools) = router()
        let job = ForgeJob(name: "linux-only checks / lint", runnerName: nil, repository: "acme/web", labels: nil)
        let decision = RuntimeRouter.assign(job: job, config: model, defaultPool: defaultPool, pools: pools)
        XCTAssertEqual(decision.pool.runtime, .appleContainer)
    }

    func testDemandBucketing() {
        let (model, _, _) = router()
        let bucketed = model.demandByPool(for: jobs([
            ("acme/ios-app", "build", nil),
            ("acme/api", "build", nil),
            ("acme/api", "build2", nil),
            ("acme/other", "misc", nil),
        ]), forgeID: .github)
        XCTAssertEqual(bucketed[.tart], 2, "ios-app route + default")
        XCTAssertEqual(bucketed[.appleContainer], 2, "api route counts 2")
    }

    // MARK: - Weighted capacity partition

    func testPartitionSplitsBudgetByWeights() {
        let partition = RuntimeCapacity.partition(
            hostUsableCPU: 10, hostUsableMemoryGB: 28,
            weights: ["tart": 0.6, "appleContainer": 0.4],
            defaultRuntime: .tart,
            shape: { $0 == .appleContainer ? (2, 4) : (4, 8) }
        )
        // tart: 6 CPU / 16.8 GB → 1 VM of (4, 8); remainder after containers.
        // appleContainer: 4 CPU / 11.2 GB → 2 containers of (2, 4).
        XCTAssertEqual(partition.caps[.appleContainer], 2)
        XCTAssertEqual(partition.caps[.tart], 1, "tart gets the 0.6 remainder: 6 CPU - 0 = 6 usable → 1 VM of 4")
    }

    func testPartitionRemainderGoesToDefault() {
        let partition = RuntimeCapacity.partition(
            hostUsableCPU: 8, hostUsableMemoryGB: 32,
            weights: ["appleContainer": 0.5],
            defaultRuntime: .tart,
            shape: { $0 == .appleContainer ? (2, 4) : (4, 8) }
        )
        XCTAssertEqual(partition.caps[.appleContainer], 2, "4 CPU/16 GB → 2×(2 CPU, 4 GB)")
        XCTAssertEqual(partition.caps[.tart], 1, "remainder 4 CPU/16 GB → 1×(4 CPU, 8 GB)")
    }

    func testPartitionWithoutWeightsGivesAllToDefault() {
        let partition = RuntimeCapacity.partition(
            hostUsableCPU: 8, hostUsableMemoryGB: 32,
            weights: [:],
            defaultRuntime: .tart,
            shape: { $0 == .appleContainer ? (2, 4) : (4, 8) }
        )
        XCTAssertEqual(partition.caps[.tart], 2)
        XCTAssertNil(partition.caps[.appleContainer], "unweighted non-default runtimes get no reserved partition")
    }

    // MARK: - Config parsing & validation

    func testRuntimesSectionParses() throws {
        let cfg = try ConfigLoader.parse("""
        repo: "acme"
        labels: ["orchard"]
        container:
          image: "orchard-ci-linux"
        runtimes:
          default: tart
          budget: {tart: 0.6, appleContainer: 0.4}
          routes:
            - pattern: "acme/api"
              runtime: appleContainer
            - pattern: "acme/web@Nightly"
              runtime: appleContainer
        """)
        let runtimes = try XCTUnwrap(cfg.runtimes)
        XCTAssertEqual(runtimes.defaultRuntime, "tart")
        XCTAssertEqual(runtimes.routes.count, 2)
        XCTAssertEqual(runtimes.routes.first?.pattern, "acme/api")
        XCTAssertEqual(runtimes.budget["appleContainer"], 0.4)
    }

    func testRuntimesRejectsUnknownRuntime() {
        XCTAssertThrowsError(try ConfigLoader.parse("""
        repo: "acme"
        labels: ["orchard"]
        runtimes:
          routes:
            - pattern: "acme/api"
              runtime: kubernetes
        """)) { error in
            XCTAssertTrue("\(error)".contains("unknown runtime"), "got: \(error)")
        }
    }

    func testRuntimesRejectsDockerRoutesWithoutDockerConfig() {
        XCTAssertThrowsError(try ConfigLoader.parse("""
        repo: "acme"
        labels: ["orchard"]
        runtimes:
          routes:
            - pattern: "acme/api"
              runtime: docker
        """)) { error in
            XCTAssertTrue("\(error)".contains("no docker: section"), "got: \(error)")
        }
    }

    func testRuntimesRejectsContainerRoutesWithoutContainerConfig() {
        XCTAssertThrowsError(try ConfigLoader.parse("""
        repo: "acme"
        labels: ["orchard"]
        runtimes:
          routes:
            - pattern: "acme/api"
              runtime: appleContainer
        """)) { error in
            XCTAssertTrue("\(error)".contains("no container: section"))
        }
    }

    func testRuntimesRejectsOversubscribedBudget() {
        XCTAssertThrowsError(try ConfigLoader.parse("""
        repo: "acme"
        labels: ["orchard"]
        container:
          image: "img"
        runtimes:
          budget: {tart: 0.8, appleContainer: 0.8}
        """)) { error in
            XCTAssertTrue("\(error)".contains("must be <= 1.0"))
        }
    }

    func testRuntimesRejectsMalformedPatterns() {
        XCTAssertThrowsError(try ConfigLoader.parse("""
        repo: "acme"
        labels: ["orchard"]
        container:
          image: "img"
        runtimes:
          routes:
            - pattern: "just-a-name"
              runtime: tart
        """)) { error in
            XCTAssertTrue("\(error)".contains("owner/name"))
        }
    }

    func testRuntimesRejectsDuplicatePatterns() {
        XCTAssertThrowsError(try ConfigLoader.parse("""
        repo: "acme"
        labels: ["orchard"]
        container:
          image: "img"
        runtimes:
          routes:
            - pattern: "acme/api"
              runtime: appleContainer
            - pattern: "acme/api"
              runtime: tart
        """)) { error in
            XCTAssertTrue("\(error)".contains("duplicate"))
        }
    }

    // MARK: - Engine spawn selection (mixed fleet)

    private func makeEngine(runtimes: OrchardConfig.RuntimeConfig?) -> FleetEngine {
        var cfg = makeTestConfig()
        cfg.repo = "acme"  // org scope: queued jobs carry repo attribution
        cfg.container = .init(image: "orchard-ci-linux", cpus: 2, memoryGB: 4)
        cfg.runtimes = runtimes
        return FleetEngine(
            config: cfg, github: FakeGitHub(), tart: FakeTart(),
            store: makeTestStore(), ssh: FakeSSH(), host: testHost,
            containerShell: ContainerFakingShell()
        )
    }

    func testEngineRoutesDemandToBothRuntimes() async throws {
        let engine = makeEngine(runtimes: mixedConfig())
        // The engine's forge demand comes from queuedJobs; bucketing is
        // covered by the router tests above. Here we pin selectRuntime
        // directly (deterministic, no sleeping spawn loop).
        let demand: [RuntimeID: Int] = [.tart: 1, .appleContainer: 2]
        let chosen = engine.selectRuntime(
            demand: demand, active: [:], caps: [.tart: 1, .appleContainer: 2],
            fallback: engine.routing.defaultRuntime
        )
        XCTAssertEqual(chosen, .appleContainer, "most unmet demand wins")

        let afterCap = engine.selectRuntime(
            demand: demand, active: [.appleContainer: 2], caps: [.tart: 1, .appleContainer: 2],
            fallback: engine.routing.defaultRuntime
        )
        XCTAssertEqual(afterCap, .tart, "exhausted partitions are skipped")
    }

    func testEngineStatusCarriesCapacityByRuntime() async throws {
        let engine = makeEngine(runtimes: mixedConfig())
        let status = await engine.status()
        let caps = try XCTUnwrap(status.capacityByRuntime)
        XCTAssertEqual(Set(caps.keys), Set(["tart", "appleContainer"]))
    }

    func testSinglePoolEngineHasNoPartitionStatus() async throws {
        let engine = makeEngine(runtimes: nil)
        let status = await engine.status()
        XCTAssertNil(status.capacityByRuntime, "single-pool fleets keep the legacy status shape")
    }

    func waitUntil(timeout: TimeInterval, _ condition: () async -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if await condition() { return }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        XCTFail("condition not met within \(timeout)s")
    }
}
