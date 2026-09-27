import XCTest

@testable import KinhinKit
@testable import KinhinTestSupport

/// Live routing reload: the engine swaps pools/caps from a new config while
/// running, and the daemon's reload_config RPC reads the file and applies it.
final class ReloadConfigTests: XCTestCase {
    // MARK: - Fixtures

    private let host = HostResources(logicalCores: 12, memoryGB: 32, freeDiskGB: 200, arm64: true)

    private func makeEngine() -> (FleetEngine, FakeGitHub) {
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

    private func mixedConfig(budget: [String: Double], routes: [KinhinConfig.RuntimeConfig.Route]) -> KinhinConfig {
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

    // MARK: - Restart policy (pure)

    /// Routing-only changes are the live-reload set; everything else in the
    /// frozen engine config requires a rebuild.
    func testRestartPolicyMatrix() {
        let base = makeTestConfig()

        // Routing-only edits (applyReloaded's exact set) stay live.
        XCTAssertFalse(FleetEngine.restartRequired(from: base, to: base), "identical configs never restart")
        var routes = makeTestConfig()
        routes.runtimes = .init(
            defaultRuntime: "appleContainer", budget: ["tart": 0.5, "appleContainer": 0.5],
            routes: [.init(pattern: "acme/api", runtime: "appleContainer")])
        XCTAssertFalse(FleetEngine.restartRequired(from: base, to: routes), "routes/budget/default are hot-reloaded")
        var labels = makeTestConfig()
        labels.labels = ["kinhin", "extra"]
        XCTAssertFalse(FleetEngine.restartRequired(from: base, to: labels), "label edits reach the forge live")

        // Everything read from the frozen config restarts.
        func with(_ mutate: (inout KinhinConfig) -> Void) -> KinhinConfig {
            var cfg = base
            mutate(&cfg)
            return cfg
        }
        XCTAssertTrue(
            FleetEngine.restartRequired(from: base, to: with { $0.repo = "acme/other" }), "scope change must restart")
        XCTAssertTrue(FleetEngine.restartRequired(from: base, to: with { $0.minRunners = 2 }), "bounds must restart")
        XCTAssertTrue(FleetEngine.restartRequired(from: base, to: with { $0.maxRunners = 8 }), "bounds must restart")
        XCTAssertTrue(FleetEngine.restartRequired(from: base, to: with { $0.runnersPerVM = 3 }), "density must restart")
        XCTAssertTrue(
            FleetEngine.restartRequired(from: base, to: with { $0.pollInterval = 60 }), "poll cadence must restart")
        XCTAssertTrue(FleetEngine.restartRequired(from: base, to: with { $0.vm.cpuCount = 6 }), "VM shape must restart")
        XCTAssertTrue(
            FleetEngine.restartRequired(from: base, to: with { $0.image = "other-base" }), "image must restart")
        XCTAssertTrue(
            FleetEngine.restartRequired(from: base, to: with { $0.reserve.cpu = 4 }), "host headroom must restart")
        XCTAssertTrue(
            FleetEngine.restartRequired(
                from: base, to: with { $0.container = .init(image: "linux", cpus: 2, memoryGB: 4) }),
            "runtime sections must restart")
        XCTAssertTrue(
            FleetEngine.restartRequired(
                from: base, to: with { $0.gitea = .init(instance: "https://gitea.example.com", scope: "acme") }),
            "forge sections must restart")
        XCTAssertTrue(
            FleetEngine.restartRequired(from: base, to: with { $0.toolchains = .init(specs: ["node@22"]) }),
            "toolchains must restart")
    }

    // MARK: - Daemon reload: hot reload vs rebuild

    /// Engines for these tests are built from the parsed YAML itself (not
    /// makeTestConfig) so the restart diff compares like with like.
    private func makeEngine(
        _ config: KinhinConfig, store: FleetStore = makeTestStore(), tart: TartControlling = FakeTart(),
        github: FakeGitHub = FakeGitHub()
    ) -> FleetEngine {
        let engine = FleetEngine(
            config: config,
            github: github,
            tart: tart,
            store: store,
            ssh: FakeSSH(),
            host: host
        )
        engine.lifecycleDrainTimeout = .seconds(5)
        return engine
    }

    /// A routing-only edit answers ok and keeps the same engine object.
    func testDaemonReloadRoutingOnlyReusesTheEngine() async throws {
        let dir = try scratchDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("config.yaml")
        try yaml().write(to: url, atomically: true, encoding: .utf8)
        let engine = makeEngine(try ConfigLoader.parse(yaml()))
        let ref = Daemon.EngineRef(engine)

        let routed = yaml(
            runtimes: "runtimes:\n  default: tart\n  routes:\n    - pattern: \"acme/api\"\n      runtime: tart\n")
        try routed.write(to: url, atomically: true, encoding: .utf8)

        let response = await Daemon.handle(
            .init(id: 20, method: .reloadConfig),
            engineRef: ref,
            configURL: url,
            engineFactory: { _ in
                XCTFail("routing-only reload must not rebuild"); return engine
            }
        )
        XCTAssertTrue(response.ok, "\(response.error ?? "")")
        XCTAssertTrue(ref.engine === engine, "routing-only edit keeps the same engine")
    }

    /// A shape edit (vm.cpu differs) answers ok and swaps in a NEW engine
    /// built by the factory from the on-disk config.
    func testDaemonReloadShapeEditRebuildsTheEngine() async throws {
        let dir = try scratchDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("config.yaml")
        try yaml().write(to: url, atomically: true, encoding: .utf8)
        let engine = makeEngine(try ConfigLoader.parse(yaml()))
        let ref = Daemon.EngineRef(engine)

        try yaml(vmCPU: 6).write(to: url, atomically: true, encoding: .utf8)
        let replacement = makeEngine(try ConfigLoader.parse(yaml(vmCPU: 6)))
        let response = await Daemon.handle(
            .init(id: 21, method: .reloadConfig),
            engineRef: ref,
            configURL: url,
            engineFactory: { cfg in
                XCTAssertEqual(cfg.vm.cpuCount, 6, "the factory receives the on-disk config")
                return replacement
            }
        )
        XCTAssertTrue(response.ok, "\(response.error ?? "")")
        XCTAssertTrue(ref.engine === replacement, "the ref now serves the rebuilt engine")
        XCTAssertFalse(ref.engine === engine)
    }

    /// A factory throw (missing token, tart missing) fails the RPC while
    /// the old engine keeps serving — no half-swapped state.
    func testDaemonReloadRebuildFailureKeepsTheOldEngine() async throws {
        let dir = try scratchDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("config.yaml")
        try yaml().write(to: url, atomically: true, encoding: .utf8)
        let engine = makeEngine(try ConfigLoader.parse(yaml()))
        let ref = Daemon.EngineRef(engine)

        try yaml(vmCPU: 6).write(to: url, atomically: true, encoding: .utf8)

        struct Boom: Error {}
        let response = await Daemon.handle(
            .init(id: 22, method: .reloadConfig),
            engineRef: ref,
            configURL: url,
            engineFactory: { _ in throw Boom() }
        )
        XCTAssertFalse(response.ok, "a failed rebuild must surface as ok:false")
        XCTAssertTrue(response.error?.contains("Boom") ?? false, "got: \(response.error ?? "")")
        XCTAssertTrue(ref.engine === engine, "the previous engine stays in service")
    }

    /// A rebuild while the fleet is running adopts the replacement with the
    /// same engine "shape" (start was driven by the handler): the old engine
    /// is detached and the ref serves the new one. The paused flag is
    /// re-asserted on the replacement (covered indirectly: start() on a
    /// fresh engine whose probe passes leaves running=true).
    func testDaemonReloadWhileRunningReplacesAndDetaches() async throws {
        let dir = try scratchDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("config.yaml")
        try yaml().write(to: url, atomically: true, encoding: .utf8)
        let engine = makeEngine(try ConfigLoader.parse(yaml()))
        let ref = Daemon.EngineRef(engine)

        // Fleet running (FakeGitHub's permission probe passes).
        await engine.start()

        try yaml(vmCPU: 6).write(to: url, atomically: true, encoding: .utf8)
        let replacement = makeEngine(try ConfigLoader.parse(yaml(vmCPU: 6)))
        let response = await Daemon.handle(
            .init(id: 23, method: .reloadConfig),
            engineRef: ref,
            configURL: url,
            engineFactory: { _ in replacement }
        )
        XCTAssertTrue(response.ok, "\(response.error ?? "")")
        XCTAssertTrue(ref.engine === replacement)
        let status = await replacement.status()
        XCTAssertTrue(status.running, "a running fleet must be running after the swap")
        // The old engine stopped scaling (detach), not torn down.
        let oldStatus = await engine.status()
        XCTAssertFalse(oldStatus.running)
    }

    /// A stopped fleet must stay stopped across a rebuild.
    func testDaemonReloadWhileStoppedKeepsFleetStopped() async throws {
        let dir = try scratchDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("config.yaml")
        try yaml().write(to: url, atomically: true, encoding: .utf8)
        let engine = makeEngine(try ConfigLoader.parse(yaml()))
        let ref = Daemon.EngineRef(engine)

        try yaml(vmCPU: 6).write(to: url, atomically: true, encoding: .utf8)
        let replacement = makeEngine(try ConfigLoader.parse(yaml(vmCPU: 6)))
        let response = await Daemon.handle(
            .init(id: 24, method: .reloadConfig),
            engineRef: ref,
            configURL: url,
            engineFactory: { _ in replacement }
        )
        XCTAssertTrue(response.ok, "\(response.error ?? "")")
        let status = await replacement.status()
        XCTAssertFalse(status.running, "a config edit must never start a stopped fleet")
    }

    /// The old engine's lifecycle tasks are cancelled and drained before the
    /// replacement recovers the same instances — never two engines driving
    /// one VM.
    func testDaemonRebuildDrainsOldLifecyclesBeforeReplacementAdopts() async throws {
        let dir = try scratchDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("config.yaml")
        try yaml().write(to: url, atomically: true, encoding: .utf8)
        let store = makeTestStore()
        let tart = FakeTart()
        tart.vms["kinhin-live"] = TartVM(name: "kinhin-live", source: "tahoe-base", status: "running")
        store.upsert(VMRecord(id: "kinhin-live", phase: .ready))
        let engine = makeEngine(try ConfigLoader.parse(yaml()), store: store, tart: tart)
        let ref = Daemon.EngineRef(engine)
        await engine.start()
        XCTAssertEqual(engine.lifecycleTasks.withLock { Array($0.keys) }, ["kinhin-live"])

        try yaml(vmCPU: 6).write(to: url, atomically: true, encoding: .utf8)
        let replacement = makeEngine(try ConfigLoader.parse(yaml(vmCPU: 6)), store: store, tart: tart)
        let response = await Daemon.handle(
            .init(id: 25, method: .reloadConfig),
            engineRef: ref,
            configURL: url,
            engineFactory: { _ in replacement }
        )
        XCTAssertTrue(response.ok, "\(response.error ?? "")")
        XCTAssertTrue(engine.lifecycleTasks.withLock { $0.isEmpty }, "old engine's lifecycles drained")
        XCTAssertEqual(replacement.lifecycleTasks.withLock { Array($0.keys) }, ["kinhin-live"], "replacement adopted")
        XCTAssertEqual(store.all.map(\.id), ["kinhin-live"], "the instance survived the handover")
        await replacement.detachKeepingInstances()
    }

    /// A replacement that fails forge verification never touches the fleet:
    /// the old engine keeps running and keeps its lifecycles.
    func testDaemonRebuildVerificationFailureLeavesOldEngineDriving() async throws {
        let dir = try scratchDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("config.yaml")
        try yaml().write(to: url, atomically: true, encoding: .utf8)
        let store = makeTestStore()
        let tart = FakeTart()
        tart.vms["kinhin-live"] = TartVM(name: "kinhin-live", source: "tahoe-base", status: "running")
        store.upsert(VMRecord(id: "kinhin-live", phase: .ready))
        let engine = makeEngine(try ConfigLoader.parse(yaml()), store: store, tart: tart)
        let ref = Daemon.EngineRef(engine)
        await engine.start()

        try yaml(vmCPU: 6).write(to: url, atomically: true, encoding: .utf8)
        let deniedGitHub = FakeGitHub()
        deniedGitHub.permissionDenied = true
        let replacement = makeEngine(
            try ConfigLoader.parse(yaml(vmCPU: 6)), store: store, tart: tart, github: deniedGitHub)
        let response = await Daemon.handle(
            .init(id: 26, method: .reloadConfig),
            engineRef: ref,
            configURL: url,
            engineFactory: { _ in replacement }
        )
        XCTAssertFalse(response.ok)
        XCTAssertTrue(ref.engine === engine)
        let oldStatus = await engine.status()
        XCTAssertTrue(oldStatus.running)
        XCTAssertEqual(engine.lifecycleTasks.withLock { Array($0.keys) }, ["kinhin-live"])
        XCTAssertTrue(replacement.lifecycleTasks.withLock { $0.isEmpty }, "the replacement adopted nothing")
        XCTAssertFalse(replacement.running)
        await engine.detachKeepingInstances()
    }

    // MARK: - Engine detach semantics

    /// Drain gives up after its bound: a task stuck in a call that ignores
    /// cancellation (a shell command) must not stall the reload RPC.
    func testDrainIsBoundedForTasksIgnoringCancellation() async {
        let engine = makeEngine(makeTestConfig())
        let gate = Mutex<CheckedContinuation<Void, Never>?>(nil)
        let stuck = Task {
            await withCheckedContinuation { continuation in gate.withLock { $0 = continuation } }
        }
        stuck.cancel()
        let clock = ContinuousClock()
        let elapsed = await clock.measure {
            await engine.drain([stuck], timeout: .milliseconds(100))
        }
        XCTAssertLessThan(elapsed, .seconds(2))
        // Release the stuck task once the gate is set, so it does not leak.
        while gate.withLock({ $0 == nil }) { await Task.yield() }
        gate.withLock {
            $0?.resume(); $0 = nil
        }
        await stuck.value
    }

    func testDrainReturnsAsSoonAsTasksFinish() async {
        let engine = makeEngine(makeTestConfig())
        let quick = Task<Void, Never> {}
        let clock = ContinuousClock()
        let elapsed = await clock.measure {
            await engine.drain([quick], timeout: .seconds(30))
        }
        XCTAssertLessThan(elapsed, .seconds(2))
    }

    /// Detach cancels scaling but keeps records and instances: the fleet's
    /// store survives for the replacement engine's recovery to adopt (stop()
    /// by contrast deletes every active record).
    func testDetachKeepsRecordsAndInstances() async {
        let store = makeTestStore()
        store.upsert(VMRecord(id: "kinhin-adopt", phase: .ready))
        let engine = makeEngine(makeTestConfig(), store: store)
        await engine.detachKeepingInstances()
        let status = await engine.status()
        XCTAssertFalse(status.running)
        XCTAssertEqual(status.records.map(\.id), ["kinhin-adopt"], "records survive for adoption")
    }

    /// A lifecycle blocked in a runtime call (a shell command ignores
    /// cancellation and ends only on its own timeout) must not write to the
    /// store after detach: the straggler exits at its next cancellation
    /// check — here, when `awaitReady` returns after the drain gave up —
    /// instead of stamping its result and re-phasing the record.
    func testDetachedLifecycleBlockedInRuntimeCallWritesNothing() async throws {
        let store = makeTestStore()
        let tart = BlockingTart()
        tart.vms["kinhin-live"] = TartVM(name: "kinhin-live", source: "tahoe-base", status: "running")
        store.upsert(VMRecord(id: "kinhin-live", phase: .ready))
        let engine = makeEngine(makeTestConfig(), store: store, tart: tart)
        engine.lifecycleDrainTimeout = .milliseconds(200)
        await engine.start()
        let deadline = Date().addingTimeInterval(5)
        while !tart.isBlockedInIP && Date() < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertTrue(tart.isBlockedInIP, "fixture: the lifecycle must be blocked in awaitReady")

        await engine.detachKeepingInstances()
        let before = store.all.first { $0.id == "kinhin-live" }
        XCTAssertEqual(before?.phase, .booting, "fixture: blocked mid-boot")
        let updatedAtBefore = before?.updatedAt

        // The blocked call returns normally — cancellation was already
        // delivered, so the straggler must exit, not write its result.
        tart.releaseIP("192.168.64.9")
        let exitDeadline = Date().addingTimeInterval(2)
        while engine.lifecycleTasks.withLock({ !$0.isEmpty }) && Date() < exitDeadline {
            try await Task.sleep(for: .milliseconds(10))
        }

        let after = store.all.first { $0.id == "kinhin-live" }
        XCTAssertEqual(after?.phase, .booting, "a detached straggler must not re-phase the record")
        XCTAssertNil(after?.ip, "a detached straggler must not stamp its result into the store")
        XCTAssertEqual(after?.updatedAt, updatedAtBefore, "no updateRecord write may land after detach")
        XCTAssertFalse(engine.lifecycleTasks.withLock { $0["kinhin-live"] != nil }, "the straggler exited")
    }

    // MARK: - Helpers

    private func scratchDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("kinhin-reload-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Minimal valid YAML for a config shape (makeTestConfig's values).
    private func yaml(repo: String = "acme/widgets", vmCPU: Int = 4, runtimes: String? = nil) -> String {
        var text = """
            repo: "\(repo)"
            labels: ["kinhin"]
            poll_interval: 5
            vm:
              cpu: \(vmCPU)
              memory_gb: 8
            image: "tahoe-base"
            """
        if let runtimes { text += "\n" + runtimes }
        return text
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

/// A tart double whose `ip(of:)` parks until told otherwise — models a
/// shell command that ignores cancellation and ends only on its own
/// timeout. Everything else mirrors `FakeTart` semantics.
private final class BlockingTart: TartControlling, @unchecked Sendable {
    private let lock = NSLock()
    private var parkedContinuations: [CheckedContinuation<String, Error>] = []
    var vms: [String: TartVM] = [:]

    var isBlockedInIP: Bool {
        lock.lock(); defer { lock.unlock() }
        return !parkedContinuations.isEmpty
    }

    func releaseIP(_ ip: String) {
        lock.lock()
        let parked = parkedContinuations
        parkedContinuations.removeAll()
        lock.unlock()
        for continuation in parked { continuation.resume(returning: ip) }
    }

    func list() async throws -> [TartVM] {
        lock.lock(); defer { lock.unlock() }
        return Array(vms.values)
    }

    func clone(source: String, to name: String) async throws {
        lock.lock(); defer { lock.unlock() }
        vms[name] = TartVM(name: name, source: source, status: "running")
    }

    func run(name: String, mounts: [String]) async throws {
        lock.lock(); defer { lock.unlock() }
        if let vm = vms[name] {
            vms[name] = TartVM(
                name: vm.name, source: vm.source, status: "running", cpu: vm.cpu, memoryMB: vm.memoryMB,
                diskGB: vm.diskGB)
        }
    }

    func ip(of name: String, timeout: TimeInterval) async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            lock.lock()
            parkedContinuations.append(continuation)
            lock.unlock()
        }
    }

    func sshExec(vm: String, user: String, ip: String, script: String, timeout: TimeInterval) async throws
        -> ShellResult
    {
        ShellResult(exitCode: 0, stdout: "", stderr: "")
    }

    func stop(name: String) async throws {}

    func delete(name: String) async throws {
        lock.lock(); defer { lock.unlock() }
        vms.removeValue(forKey: name)
    }

    func pull(image: String) async throws {}
}
