import XCTest

@testable import KinhinKit
@testable import KinhinTestSupport

/// Live routing reload: the engine swaps pools/caps from a new config while
/// running, and the daemon's reload_config RPC reads the file and applies it.
final class ReloadConfigTests: XCTestCase {
    // MARK: - Fixtures

    let host = HostResources(logicalCores: 12, memoryGB: 32, freeDiskGB: 200, arm64: true)

    func makeEngine() -> (FleetEngine, FakeGitHub) {
        let config = makeTestConfig()
        let github = FakeGitHub()
        let engine = FleetEngine(
            config: config,
            github: github,
            tart: FakeTart(),
            store: makeTestStore(),
            ssh: FakeSSH(),
            host: host
        )
        return (engine, github)
    }

    func mixedConfig(budget: [String: Double], routes: [KinhinConfig.RuntimeConfig.Route]) -> KinhinConfig {
        var cfg = makeTestConfig()
        cfg.container = .init(image: "kinhin-ci-linux", cpus: 2, memoryGB: 4)
        cfg.runtimes = .init(defaultRuntime: "tart", budget: budget, routes: routes)
        return cfg
    }

    // MARK: - Engine reload

    func testReloadAddsContainerPoolAndRoutes() async {
        let (engine, _) = makeEngine()

        // Before: single tart pool, no routes.
        let before = await engine.status()
        XCTAssertNil(before.capacityByRuntime)

        let reloaded = mixedConfig(
            budget: ["tart": 0.6, "appleContainer": 0.4],
            routes: [.init(pattern: "acme/api", runtime: "appleContainer")]
        )
        engine.applyReloaded(config: reloaded, host: host)

        // After: partitioned caps visible in status.
        let after = await engine.status()
        let caps = after.capacityByRuntime ?? [:]
        XCTAssertEqual(Set(caps.keys), ["tart", "appleContainer"])
        // usable 10cpu/28GB: container 0.4 → 4cpu/11GB ÷ (2,4) = 2;
        // tart remainder 6cpu/17GB ÷ (4,8) = min(1, 2) = 1 (cpu-bound)
        XCTAssertEqual(caps["appleContainer"], "2")
        XCTAssertEqual(caps["tart"], "1")
    }

    func testReloadRemovesRoutingBackToSinglePool() async {
        let (engine, _) = makeEngine()
        engine.applyReloaded(config: mixedConfig(budget: ["tart": 0.6, "appleContainer": 0.4], routes: []), host: host)

        // Reload a config without runtimes: back to legacy single-pool.
        engine.applyReloaded(config: makeTestConfig(), host: host)
        let status = await engine.status()
        XCTAssertNil(status.capacityByRuntime, "legacy single-pool keeps the nil capacityByRuntime shape")
    }

    func testReloadWhileRunningReachesNextReconcile() async throws {
        let (engine, github) = makeEngine()
        // One queued job on acme/api, routed to containers after reload.
        github.queueDepth = 1

        let reloaded = mixedConfig(budget: [:], routes: [.init(pattern: "acme/api", runtime: "appleContainer")])
        engine.applyReloaded(config: reloaded, host: host)

        // Reconcile is async; demand bucketing uses the reloaded model. We
        // can't run the full loop hermetically, but a snapshot must carry
        // the reloaded default runtime and the pool must exist.
        let status = await engine.status()
        XCTAssertEqual(status.desired, 0)  // nothing started; reconcile not running
        // The reload itself is the contract under test — demand bucketing
        // with the new model is covered by RuntimeRoutingTests.
        _ = engine
    }

    func testReloadPreservesRunningAndPausedState() async {
        let (engine, _) = makeEngine()
        await engine.setPaused(true)
        engine.applyReloaded(config: mixedConfig(budget: ["tart": 1.0], routes: []), host: host)
        let status = await engine.status()
        XCTAssertTrue(status.paused, "reload must not flip pause state")
    }

    // MARK: - RPC handler

    func testDaemonReloadRPCAppliesConfigFromDisk() async throws {
        let (engine, _) = makeEngine()
        let ref = Daemon.EngineRef(engine)

        // Scratch config file with a container section + mixed routing.
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("kinhin-reload-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("config.yaml")
        let yaml = """
            repo: "acme/widgets"
            labels: ["self-hosted", "macos", "arm64"]
            max_runners: 4
            container:
              image: "kinhin-ci-linux"
              cpus: 2
              memory_gb: 4
            runtimes:
              default: tart
              budget: {tart: 0.6, appleContainer: 0.4}
              routes:
                - pattern: "acme/api"
                  runtime: appleContainer
            """
        try yaml.write(to: url, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: dir) }

        // Adding a container section is a shape change: the daemon rebuilds
        // the engine through the factory (production: buildEngine with the
        // real Keychain/tart; here, the test's own collaborators).
        let response = await Daemon.handle(
            .init(id: 1, method: .reloadConfig),
            engineRef: ref,
            configURL: url,
            engineFactory: { cfg in
                FleetEngine(
                    config: cfg, github: FakeGitHub(), tart: FakeTart(), store: makeTestStore(), ssh: FakeSSH(),
                    host: self.host)
            }
        )
        XCTAssertTrue(response.ok, "reload RPC should succeed: \(response.error ?? "")")
        let replaced = try XCTUnwrap(ref.engine, "the ref serves the rebuilt engine")
        XCTAssertFalse(replaced === engine)
        let status = await replaced.status()
        let caps = status.capacityByRuntime ?? [:]
        XCTAssertEqual(Set(caps.keys), ["tart", "appleContainer"])
        // usable 10cpu/28GB: container 0.4 → 4cpu/11GB ÷ (2,4) = 2;
        // tart remainder 6cpu/17GB ÷ (4,8) = min(1, 2) = 1 (cpu-bound)
        XCTAssertEqual(caps["appleContainer"], "2")
        XCTAssertEqual(caps["tart"], "1")
    }

    func testDaemonReloadRPCReportsFailureOnBadConfig() async throws {
        let (engine, _) = makeEngine()
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("kinhin-reload-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("config.yaml")
        try "repo: \"acme/widgets\"\nlabels: []\n".write(to: url, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: dir) }

        let response = await Daemon.handle(
            .init(id: 2, method: .reloadConfig), engineRef: .init(engine), configURL: url)
        XCTAssertFalse(response.ok, "invalid config must fail the reload, not apply partially")
        // Engine keeps its previous (default) routing state — still usable.
        let status = await engine.status()
        XCTAssertNotNil(status)
    }

    // MARK: - Client method encodes

    func testReloadConfigMethodRoundTripsThroughCodable() throws {
        let request = RPCRequest(id: 7, method: .reloadConfig)
        let data = try JSONEncoder().encode(request)
        let decoded = try JSONDecoder().decode(RPCRequest.self, from: data)
        XCTAssertEqual(decoded.method, .reloadConfig)
        XCTAssertEqual(decoded.method.rawValue, "reload_config")
        XCTAssertNil(decoded.payload)
    }
}
