import XCTest

@testable import KinhinKit
@testable import KinhinTestSupport

/// The reconcile pass only decides and hands off: teardowns, the spawn stagger
/// and forge re-attachment run outside it, so none of them can hold up the
/// next look at the queue.
final class BackgroundWorkTests: XCTestCase {
    let host = HostResources(logicalCores: 12, memoryGB: 32, freeDiskGB: 200, arm64: true)

    private func makeEngine(
        config: KinhinConfig? = nil, tart: FakeTart, github: FakeGitHub = FakeGitHub(),
        stagger: Duration = .zero
    ) -> FleetEngine {
        FleetEngine(
            config: config ?? makeTestConfig(), github: github, tart: tart, store: makeTestStore(), ssh: FakeSSH(),
            host: host,
            dependencies: .init(
                tokenLoader: { _, _ in "t" }, lifecycleDrainTimeout: .milliseconds(300), spawnStagger: stagger,
                exitWatchInterval: .milliseconds(20)))
    }

    private func addInstance(
        _ id: String, phase: VMPhase, to engine: FleetEngine, tart: FakeTart
    ) {
        var record = VMRecord(id: id, phase: phase)
        record.runtimeID = .tart
        engine.store.upsert(record)
        tart.vms[id] = TartVM(name: id, source: "base", status: "running")
    }

    // MARK: - Deletes

    func testPassDoesNotWaitForATeardownAndNeverStartsItTwice() async throws {
        let tart = FakeTart()
        let engine = makeEngine(tart: tart)
        addInstance("kinhin-slow", phase: .failed, to: engine, tart: tart)
        tart.blockNextStop()

        let started = ContinuousClock.now
        try await engine.reconcileOnce()
        XCTAssertLessThan(ContinuousClock.now - started, .seconds(2), "the pass returned while the teardown is parked")
        await tart.waitUntilStopParked()
        XCTAssertTrue(tart.isBlockedInStop)

        // The next pass finds the instance mid-delete and leaves it alone.
        try await engine.reconcileOnce()
        XCTAssertEqual(tart.deleteCalls, [], "still parked in the first teardown")
        XCTAssertEqual(
            engine.spawnBackoff.withLock { $0.entries[.tart]?.failures }, 1, "one failure is counted once, not per pass"
        )

        tart.releaseStop()
        await engine.settleDeletes()
        XCTAssertEqual(tart.stopCalls, ["kinhin-slow"], "single-flight: one teardown per instance")
        XCTAssertNil(engine.store.all.first { $0.id == "kinhin-slow" }, "the teardown finished in the background")
    }

    func testScaleDownTeardownsRunOutsideThePass() async throws {
        var cfg = makeTestConfig()
        cfg.minRunners = 0
        let tart = FakeTart()
        let engine = makeEngine(config: cfg, tart: tart)
        addInstance("kinhin-idle", phase: .ready, to: engine, tart: tart)
        tart.blockNextStop()

        let started = ContinuousClock.now
        try await engine.reconcileOnce()
        XCTAssertLessThan(ContinuousClock.now - started, .seconds(2))
        await tart.waitUntilStopParked()
        tart.releaseStop()
        await engine.settleDeletes()
        XCTAssertNil(engine.store.all.first { $0.id == "kinhin-idle" })
    }

    func testDetachWaitsForABackgroundTeardown() async throws {
        let tart = FakeTart()
        let engine = makeEngine(tart: tart)
        addInstance("kinhin-slow", phase: .failed, to: engine, tart: tart)
        tart.blockNextStop()
        try await engine.reconcileOnce()
        await tart.waitUntilStopParked()

        let finished = ContinuousClock.now
        await engine.detachKeepingInstances()  // bounded by lifecycleDrainTimeout (300 ms), not by the parked stop
        XCTAssertLessThan(ContinuousClock.now - finished, .seconds(5))
        tart.releaseStop()
        await engine.settleDeletes()
    }

    /// Engine stop deletes every active instance concurrently: one stuck teardown neither serializes the
    /// others behind it nor lets the stop run past its budget (the RPC handler gives it 120 s).
    func testStopDeletesConcurrentlyAndWithinItsBudget() async throws {
        let tart = FakeTart()
        let engine = makeEngine(tart: tart)
        for index in 0..<4 { addInstance("kinhin-\(index)", phase: .ready, to: engine, tart: tart) }
        tart.blockNextStop()

        let started = ContinuousClock.now
        await engine.deleteAllActiveVMs(budget: .milliseconds(500))
        let elapsed = ContinuousClock.now - started
        XCTAssertLessThan(elapsed, .seconds(5), "stop returns at its budget although one teardown is stuck")
        XCTAssertEqual(tart.deleteCalls.count, 3, "the other three were not queued behind the stuck one")
        XCTAssertEqual(engine.store.all.count, 1)
        XCTAssertEqual(engine.store.all.first?.phase, .deleting, "the stuck one stays recorded for the next start")

        tart.releaseStop()
        await waitForCondition { engine.store.all.isEmpty }
    }

    // MARK: - Spawn stagger

    func testStaggerNeverBlocksThePassAndSpacesTheLifecycleStarts() async throws {
        var cfg = makeTestConfig()
        cfg.maxRunners = 3
        cfg.vm.cpuCount = 1
        cfg.vm.memoryGB = 1
        let tart = FakeTart()
        let github = FakeGitHub()
        github.queueDepth = 3
        let engine = makeEngine(config: cfg, tart: tart, github: github, stagger: .seconds(30))

        let started = ContinuousClock.now
        try await engine.reconcileOnce()
        XCTAssertLessThan(ContinuousClock.now - started, .seconds(5), "the pass does not sleep between spawns")
        XCTAssertEqual(engine.store.all.count, 3, "all three instances are recorded at once")
        // Only the first lifecycle is admitted; the others wait for their slot.
        await waitForCondition { tart.cloneCalls.count == 1 }
        try await Task.sleep(for: .milliseconds(150))
        XCTAssertEqual(tart.cloneCalls.count, 1, "the second and third wait out the stagger inside their lifecycle")
        await engine.detachKeepingInstances()  // cancels the waiting lifecycles
    }

    func testPacerAdmitsTheFirstAtOnceThenSpacesTheRest() async throws {
        let pacer = SpawnPacer(interval: .milliseconds(150))
        let started = ContinuousClock.now
        try await pacer.admit()
        XCTAssertLessThan(ContinuousClock.now - started, .milliseconds(100))
        try await pacer.admit()
        try await pacer.admit()
        XCTAssertGreaterThanOrEqual(ContinuousClock.now - started, .milliseconds(290))
    }

    func testPacerWithZeroIntervalNeverWaits() async throws {
        let pacer = SpawnPacer(interval: .zero)
        let started = ContinuousClock.now
        for _ in 0..<50 { try await pacer.admit() }
        XCTAssertLessThan(ContinuousClock.now - started, .milliseconds(200))
    }

    func testPacerPropagatesCancellationWhileWaiting() async {
        let pacer = SpawnPacer(interval: .seconds(30))
        try? await pacer.admit()  // takes the free slot
        let waiter = Task { try await pacer.admit() }
        try? await Task.sleep(for: .milliseconds(50))
        waiter.cancel()
        do {
            try await waiter.value
            XCTFail("a cancelled waiter must not be admitted")
        } catch is CancellationError {
        } catch {
            XCTFail("unexpected \(error)")
        }
    }

    // MARK: - Forge retry

    func testPassAttachesADetachedForgeInTheBackground() async throws {
        let github = FakeGitHub()
        github.permissionDenied = true
        let tart = FakeTart()
        let engine = makeEngine(tart: tart, github: github)
        await engine.start()
        XCTAssertNil(engine.forges["github"], "dropped at startup")
        // Startup found no usable forge and stopped; serve anyway so the pass runs its retry.
        engine.markRunning()

        github.permissionDenied = false
        engine.forgeState.withLock { $0.retry.nextAttempt = .distantPast }
        try await engine.reconcileOnce()
        await waitForCondition { engine.forges["github"] != nil }
        await waitForCondition { engine.forgeState.withLock { $0.retry.inFlight == nil } }  // clears its own slot
        await engine.stop()
    }
}
