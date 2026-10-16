import Synchronization
import XCTest

@testable import KinhinKit
@testable import KinhinTestSupport

/// `FleetEngine.handOver(to:)` ordering and the daemon's mutation gate: the
/// replacement never adopts anything until the old engine has drained, and a
/// mutating RPC arriving mid-reload runs on the engine that owns the fleet
/// afterwards.
final class EngineHandOverTests: XCTestCase {
    let host = HostResources(logicalCores: 12, memoryGB: 32, freeDiskGB: 200, arm64: true)

    func makeEngine(
        _ config: KinhinConfig, store: FleetStore, tart: FakeTart, github: FakeGitHub = FakeGitHub(),
        drainTimeout: Duration = .seconds(30)
    ) -> FleetEngine {
        FleetEngine(
            config: config, github: github, tart: tart, store: store, ssh: FakeSSH(), host: host,
            // Hermetic: without this, start() reads the real Keychain, so the
            // tests only pass on a Mac that happens to store kinhin tokens.
            dependencies: .init(tokenLoader: { _, _ in "test-token" }, lifecycleDrainTimeout: drainTimeout))
    }

    func yaml(vmCPU: Int = 4) -> String {
        """
        accounts:
          - name: github
            forge: github
            scope: "acme/widgets"
        labels: ["kinhin"]
        poll_interval: 5
        vm:
          cpu: \(vmCPU)
          memory_gb: 8
        image: "tahoe-base"
        """
    }

    func scratchConfig() throws -> (dir: URL, url: URL) {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("kinhin-handover-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("config.yaml")
        try yaml().write(to: url, atomically: true, encoding: .utf8)
        return (dir, url)
    }

    /// A store with one adoptable running VM and a tart whose next `ip` call
    /// parks, so the started engine's lifecycle blocks in awaitReady.
    func blockedFleet() -> (store: FleetStore, tart: FakeTart) {
        let store = makeTestStore()
        let tart = FakeTart()
        tart.blockIP()
        tart.vms["kinhin-live"] = TartVM(name: "kinhin-live", source: "tahoe-base", status: "running")
        store.upsert(VMRecord(id: "kinhin-live", phase: .booting))
        return (store, tart)
    }

    func lifecycleKeys(_ engine: FleetEngine) -> [String] {
        engine.lifecycleTasks.withLock { Array($0.keys) }
    }

    func startAndWaitBlocked(_ engine: FleetEngine, _ tart: FakeTart) async {
        await engine.start()
        await waitForCondition { tart.isBlockedInIP }
    }

    // MARK: - handOver ordering

    func testHandOverDoesNotLaunchReplacementUntilOldLifecyclesDrain() async throws {
        let (store, tart) = blockedFleet()
        let config = try ConfigLoader.parse(yaml())
        let old = makeEngine(config, store: store, tart: tart)
        let replacement = makeEngine(config, store: store, tart: tart)
        await startAndWaitBlocked(old, tart)

        let done = Locked(false)
        let handOver = Task {
            let result = await old.handOver(to: replacement)
            done.withLock { $0 = true }
            return result
        }
        // Detach has begun: the old engine stopped scaling, but its lifecycle
        // is still parked in the runtime call, so the drain is in progress.
        await waitForCondition { await !old.status().running }
        try await Task.sleep(for: .milliseconds(20))
        XCTAssertTrue(tart.isBlockedInIP, "the old lifecycle is still blocked")
        XCTAssertFalse(done.withLock { $0 }, "the hand-over waits for the drain")
        XCTAssertNil(replacement.reconcileTask, "the replacement has not launched")
        XCTAssertTrue(lifecycleKeys(replacement).isEmpty, "the replacement has adopted nothing yet")

        tart.releaseIP("192.168.64.9")
        let result = await handOver.value
        XCTAssertEqual(result, .handedOver(wasRunning: true, wasPaused: false))
        XCTAssertTrue(lifecycleKeys(old).isEmpty, "old lifecycles drained")
        XCTAssertEqual(lifecycleKeys(replacement), ["kinhin-live"], "replacement adopted the instance")
        XCTAssertNotNil(replacement.reconcileTask)
        await replacement.detachKeepingInstances()
    }

    func testHandOverRejectedLeavesOldEngineOwningTheFleet() async throws {
        let (store, tart) = blockedFleet()
        let config = try ConfigLoader.parse(yaml())
        let old = makeEngine(config, store: store, tart: tart)
        let denied = FakeGitHub()
        denied.permissionDenied = true
        let replacement = makeEngine(config, store: store, tart: tart, github: denied)
        await startAndWaitBlocked(old, tart)

        let result = await old.handOver(to: replacement)
        guard case .rejected = result else {
            XCTFail("expected .rejected, got \(result)")
            tart.releaseIP("192.168.64.9")
            await old.detachKeepingInstances()
            return
        }
        let oldStatus = await old.status()
        XCTAssertTrue(oldStatus.running, "the old engine is untouched")
        XCTAssertEqual(lifecycleKeys(old), ["kinhin-live"])
        XCTAssertFalse(replacement.running)
        XCTAssertTrue(lifecycleKeys(replacement).isEmpty, "the replacement adopted nothing")
        XCTAssertNil(replacement.reconcileTask)

        tart.releaseIP("192.168.64.9")
        await old.detachKeepingInstances()
    }

    // MARK: - handOver preserves state

    func testHandOverKeepsAStoppedFleetStopped() async throws {
        let (store, tart) = blockedFleet()
        let config = try ConfigLoader.parse(yaml())
        let old = makeEngine(config, store: store, tart: tart)
        let replacement = makeEngine(config, store: store, tart: tart)

        let result = await old.handOver(to: replacement)
        XCTAssertEqual(result, .handedOver(wasRunning: false, wasPaused: false))
        XCTAssertFalse(replacement.running)
        XCTAssertNil(replacement.reconcileTask)
        XCTAssertTrue(lifecycleKeys(replacement).isEmpty, "nothing launched for a stopped fleet")
        XCTAssertFalse(tart.isBlockedInIP, "no lifecycle ran")
    }

    func testHandOverKeepsAPausedFleetPaused() async throws {
        let store = makeTestStore()
        let tart = FakeTart()
        let config = try ConfigLoader.parse(yaml())
        let old = makeEngine(config, store: store, tart: tart)
        let replacement = makeEngine(config, store: store, tart: tart)
        await old.start()
        await old.setPaused(true)

        let result = await old.handOver(to: replacement)
        XCTAssertEqual(result, .handedOver(wasRunning: true, wasPaused: true))
        let status = await replacement.status()
        XCTAssertTrue(status.running)
        XCTAssertTrue(status.paused)
        await replacement.detachKeepingInstances()
    }

    // MARK: - Daemon mutation gate

    /// A stop that lands mid-reload waits for the swap and then stops the
    /// replacement; without the gate it would stop the engine being detached
    /// and leave the replacement running.
    func testStopDuringReloadRunsOnTheReplacement() async throws {
        let (dir, url) = try scratchConfig()
        defer { try? FileManager.default.removeItem(at: dir) }
        let (store, tart) = blockedFleet()
        let old = makeEngine(try ConfigLoader.parse(yaml()), store: store, tart: tart)
        let replacement = makeEngine(try ConfigLoader.parse(yaml(vmCPU: 6)), store: store, tart: tart)
        let ref = Daemon.EngineRef(old)
        await startAndWaitBlocked(old, tart)
        try yaml(vmCPU: 6).write(to: url, atomically: true, encoding: .utf8)

        let reload = Task {
            await Daemon.handle(
                .init(id: 60, method: .reloadConfig), engineRef: ref, configURL: url,
                engineFactory: { _ in replacement })
        }
        await waitForCondition { await !old.status().running }  // detach (the drain) is in flight

        let stopDone = Locked(false)
        let stop = Task {
            let response = await Daemon.handle(
                .init(id: 61, method: .stop), engineRef: ref, configURL: url, engineFactory: { _ in replacement })
            stopDone.withLock { $0 = true }
            return response
        }
        try await Task.sleep(for: .milliseconds(20))
        XCTAssertFalse(stopDone.withLock { $0 }, "stop must wait behind the in-flight reload")
        XCTAssertTrue(ref.engine === old, "the swap has not happened yet")

        tart.releaseIP("192.168.64.9")
        let reloadResponse = await reload.value
        let stopResponse = await stop.value
        XCTAssertTrue(reloadResponse.ok, "\(reloadResponse.error ?? "")")
        XCTAssertTrue(stopResponse.ok, "\(stopResponse.error ?? "")")
        XCTAssertTrue(ref.engine === replacement)
        let status = await replacement.status()
        XCTAssertFalse(status.running, "the stop ran on the replacement after the swap")
        await replacement.detachKeepingInstances()
    }

    func testReadsAreNotGatedBehindAReload() async throws {
        let (dir, url) = try scratchConfig()
        defer { try? FileManager.default.removeItem(at: dir) }
        let (store, tart) = blockedFleet()
        let old = makeEngine(try ConfigLoader.parse(yaml()), store: store, tart: tart)
        let replacement = makeEngine(try ConfigLoader.parse(yaml(vmCPU: 6)), store: store, tart: tart)
        let ref = Daemon.EngineRef(old)
        await startAndWaitBlocked(old, tart)
        try yaml(vmCPU: 6).write(to: url, atomically: true, encoding: .utf8)

        let reload = Task {
            await Daemon.handle(
                .init(id: 62, method: .reloadConfig), engineRef: ref, configURL: url,
                engineFactory: { _ in replacement })
        }
        await waitForCondition { await !old.status().running }

        let ping = await Daemon.handle(.init(id: 63, method: .ping), engineRef: ref, configURL: url)
        let status = await Daemon.handle(.init(id: 64, method: .status), engineRef: ref, configURL: url)
        XCTAssertTrue(ping.ok, "\(ping.error ?? "")")
        XCTAssertTrue(status.ok, "\(status.error ?? "")")
        XCTAssertTrue(tart.isBlockedInIP, "the reload was still in flight when the reads answered")

        tart.releaseIP("192.168.64.9")
        let reloadResponse = await reload.value
        XCTAssertTrue(reloadResponse.ok, "\(reloadResponse.error ?? "")")
        await replacement.detachKeepingInstances()
    }

    // MARK: - RPCMethod.mutatesFleet

    func testMutatesFleetCoversExactlyTheMutatingMethods() {
        let mutating: [RPCMethod] = [
            .start, .stop, .pause, .resume, .deleteVM, .replaceToken, .replaceGiteaToken, .replaceForgejoToken,
            .replaceAccountToken, .reloadConfig, .benchStart, .healingApprove, .healingDismiss,
        ]
        let reads: [RPCMethod] = [
            .status, .ping, .logs, .pipelineDetail, .pipelineLog, .benchStatus, .benchCancel, .healingStatus,
        ]
        for method in mutating { XCTAssertTrue(method.mutatesFleet, "\(method) mutates the fleet") }
        for method in reads { XCTAssertFalse(method.mutatesFleet, "\(method) is a read") }
    }
}
