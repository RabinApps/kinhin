import Synchronization
import XCTest

@testable import KinhinKit
@testable import KinhinTestSupport

/// The daemon's reload_config split: routing-only edits hot-reload the same
/// engine, shape edits rebuild through the factory, and the old engine's
/// fleet is handed over only after its lifecycles are drained.
final class DaemonRebuildTests: XCTestCase {
    let host = HostResources(logicalCores: 12, memoryGB: 32, freeDiskGB: 200, arm64: true)

    /// Engines for these tests are built from the parsed YAML itself (not
    /// makeTestConfig) so the restart diff compares like with like.
    func makeEngine(
        _ config: KinhinConfig, store: FleetStore = makeTestStore(), tart: TartControlling = FakeTart(),
        github: FakeGitHub = FakeGitHub(), drainTimeout: Duration = .seconds(5)
    ) -> FleetEngine {
        FleetEngine(
            config: config,
            github: github,
            tart: tart,
            store: store,
            ssh: FakeSSH(),
            host: host,
            dependencies: .init(tokenLoader: { _, _ in "test-token" }, lifecycleDrainTimeout: drainTimeout)
        )
    }

    func scratchDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("kinhin-reload-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Minimal valid YAML for a config shape (makeTestConfig's values).
    func yaml(repo: String = "acme/widgets", vmCPU: Int = 4, runtimes: String? = nil) -> String {
        var text = """
            accounts:
              - name: github
                forge: github
                scope: "\(repo)"
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

    // MARK: - Daemon reload: hot reload vs rebuild

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

    /// Two overlapping shape-edit reloads must not both rebuild from the same
    /// old engine (each would launch a replacement, and one would be left
    /// running with nothing referencing it): the second waits, then finds
    /// the rebuilt engine already on the new config.
    func testConcurrentReloadsRebuildOnce() async throws {
        let dir = try scratchDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("config.yaml")
        try yaml().write(to: url, atomically: true, encoding: .utf8)
        let ref = Daemon.EngineRef(makeEngine(try ConfigLoader.parse(yaml())))

        try yaml(vmCPU: 6).write(to: url, atomically: true, encoding: .utf8)
        let builds = Mutex(0)
        let factory: @Sendable (KinhinConfig) throws -> FleetEngine = { [host] cfg in
            builds.withLock { $0 += 1 }
            return FleetEngine(
                config: cfg, github: FakeGitHub(), tart: FakeTart(), store: makeTestStore(), ssh: FakeSSH(), host: host)
        }
        let responses = await withTaskGroup(of: RPCResponse.self) { group in
            for id in 0..<4 {
                group.addTask {
                    await Daemon.handle(
                        .init(id: 40 + id, method: .reloadConfig), engineRef: ref, configURL: url,
                        engineFactory: factory)
                }
            }
            return await group.reduce(into: []) { $0.append($1) }
        }
        XCTAssertTrue(responses.allSatisfy(\.ok), "\(responses.compactMap(\.error))")
        XCTAssertEqual(builds.withLock { $0 }, 1, "only the first reload may rebuild the engine")
        XCTAssertEqual(ref.engine?.activeConfig.vm.cpuCount, 6)
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
        store.upsert(VMRecord(id: "kinhin-live", phase: .booting))
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
        store.upsert(VMRecord(id: "kinhin-live", phase: .booting))
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
        let tart = FakeTart()
        tart.blockIP()
        tart.vms["kinhin-live"] = TartVM(name: "kinhin-live", source: "tahoe-base", status: "running")
        store.upsert(VMRecord(id: "kinhin-live", phase: .booting))
        let engine = makeEngine(makeTestConfig(), store: store, tart: tart, drainTimeout: .milliseconds(200))
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
}
