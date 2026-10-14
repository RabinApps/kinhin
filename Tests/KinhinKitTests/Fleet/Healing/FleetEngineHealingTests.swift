import Synchronization
import XCTest

@testable import KinhinKit
@testable import KinhinTestSupport

/// The engine's side of healing: the signals it reads from records, alerts
/// and the spawn backoff, and the fixes it carries out.
final class FleetEngineHealingTests: XCTestCase {
    private func makeEngine(
        tart: FakeTart = FakeTart(), config: KinhinConfig = makeTestConfig(),
        host: HealingHostActions = .inert, store: FleetStore = makeTestStore()
    ) -> FleetEngine {
        var dependencies = FleetEngine.Dependencies(
            tokenLoader: { _, _ in "test-token" }, watchdog: Watchdog(unwatchedGrace: .zero))
        dependencies.healingHost = host
        dependencies.healingTimings = HealingAgent.Timings(cooldown: 0, ageScale: 0, probeTTL: 0)
        return FleetEngine(
            config: config, github: FakeGitHub(), tart: tart, store: store, ssh: FakeSSH(), host: testHost,
            dependencies: dependencies)
    }

    private func warmRecord(_ id: String) -> VMRecord {
        var record = VMRecord(id: id, phase: .warm, createdAt: Date().addingTimeInterval(-60))
        record.runtime = RuntimeID.tart.rawValue
        record.updatedAt = Date().addingTimeInterval(-60)
        return record
    }

    // MARK: - Teardown and alerts

    func testAFailedTeardownIsAStuckTeardownSignal() async {
        let engine = makeEngine()
        var record = VMRecord(id: "kinhin-1700000000-aaaa0006", phase: .deleting)
        record.error = "teardown failed: tart delete exited 1"
        engine.store.upsert(record)

        let signals = await engine.healingSignals(now: Date())
        XCTAssertEqual(signals.map(\.kind), [.teardownStuck])
    }

    func testAlertsBecomeSignals() {
        func signal(_ source: String, _ message: String) -> HealingSignal? {
            FleetEngine.healingSignal(fromAlert: FleetStatusAlert(source: source, message: message))
        }
        XCTAssertEqual(signal("disk", "full")?.kind, .diskPressure)
        XCTAssertEqual(signal("account:work", "connection refused")?.subject, "work")
        XCTAssertNil(signal("account:work", "connection refused")?.evidence)
        XCTAssertEqual(signal("account:work", "HTTP 401 Bad credentials")?.evidence, .authRejected)
        XCTAssertEqual(signal("queue:gitea", "503")?.kind, .queueUnreadable)
        XCTAssertEqual(signal("reconcile", "boom")?.kind, .reconcileFailing)
        XCTAssertEqual(signal("credentials", "missing")?.kind, .credentials)
        XCTAssertNil(signal("orphans", "x"), "the orphan sweep heals itself")
        XCTAssertNil(signal("spawn-backoff", "x"), "read from the backoff itself")
        XCTAssertNil(signal("healing", "x"))
    }

    func testDiskPressurePrunesTheCacheThroughTheHost() async throws {
        let pruned = Mutex(0)
        var host = HealingHostActions.inert
        host.pruneToolchainCache = { _ in
            pruned.withLock { $0 += 1 }
            return "freed 10 MB"
        }
        var config = makeTestConfig()
        config.toolchainCache = KinhinConfig.ToolchainCacheConfig(autoPrune: true)
        let engine = makeEngine(config: config, host: host)
        await engine.statusBox.modify { $0.setAlert("disk", "disk pressure: 3 GB free") }

        await engine.healing.pass(actions: engine)

        XCTAssertEqual(pruned.withLock { $0 }, 1)
        let snapshot = await engine.healingStatus()
        XCTAssertEqual(snapshot.events.first?.detail, "freed 10 MB")
    }

    // MARK: - Spawn failures

    func testSpawnFailuresCarryTheTartHealthProbe() async throws {
        var host = HealingHostActions.inert
        host.tartHealth = { _ in .killedOnLaunch }
        let engine = makeEngine(host: host)
        engine.noteSpawnFailure(runtime: .tart, reason: "exit 137")
        engine.noteSpawnFailure(runtime: .tart, reason: "exit 137")

        let signals = await engine.healingSignals(now: Date())
        let spawn = try XCTUnwrap(signals.first { $0.kind == .spawnFailures })
        XCTAssertEqual(spawn.subject, "tart")
        XCTAssertEqual(spawn.evidence, .tartKilledOnLaunch)

        await engine.healing.pass(actions: engine)
        let snapshot = await engine.healingStatus()
        XCTAssertEqual(snapshot.pending.first?.remediation?.kind, .repairTart, "a reinstall waits for approval")
        let status = await engine.status(includeUsage: false)
        XCTAssertEqual(status.alerts?.contains { $0.source == "healing" }, true)
    }

    func testOneFailureIsNotYetAProblem() async {
        let engine = makeEngine()
        engine.noteSpawnFailure(runtime: .tart, reason: "exit 1")
        let signals = await engine.healingSignals(now: Date())
        XCTAssertFalse(signals.contains { $0.kind == .spawnFailures })
    }

    func testApprovingARepairRunsItAndClearsTheAlert() async throws {
        let repaired = Mutex(false)
        var host = HealingHostActions.inert
        host.tartHealth = { _ in .broken("exit 1") }
        host.repairTart = { _ in
            repaired.withLock { $0 = true }
            return "reinstalled tart"
        }
        let engine = makeEngine(host: host)
        engine.noteSpawnFailure(runtime: .tart, reason: "exit 1")
        engine.noteSpawnFailure(runtime: .tart, reason: "exit 1")
        await engine.healing.pass(actions: engine)
        let pending = await engine.healingStatus().pending
        let id = try XCTUnwrap(pending.first?.id)

        try await engine.approveHealing(id: id)
        try await waitUntil(timeout: 5) { await engine.healingStatus().events.first?.outcome == .succeeded }

        XCTAssertTrue(repaired.withLock { $0 })
        let status = await engine.status(includeUsage: false)
        XCTAssertNil(status.alerts?.first { $0.source == "healing" })
    }

    // MARK: - Setup checks

    func testFailingSetupChecksBecomeSignalsOnlyForRuntimesAndImages() async {
        var host = HealingHostActions.inert
        host.setupChecks = { _ in
            [
                SetupCheckResult(
                    id: "container-cli", title: "Apple container", ok: false, detail: "stopped",
                    action: "start_container_system"),
                SetupCheckResult(id: "config", title: "Config", ok: false, detail: "bad", action: "edit_config"),
                SetupCheckResult(id: "docker-cli", title: "Docker", ok: true, detail: "ok", action: nil),
            ]
        }
        let engine = makeEngine(host: host)
        let signals = await engine.healingSignals(now: Date())
        XCTAssertEqual(signals.map(\.subject), ["container-cli"])
        XCTAssertEqual(signals.first?.setupAction, "start_container_system")
    }

    func testTheSetupChecklistOnlyRunsAgainWhileItMatters() async {
        let runs = Mutex(0)
        let failing = Mutex(false)
        var host = HealingHostActions.inert
        host.setupChecks = { _ in
            runs.withLock { $0 += 1 }
            guard failing.withLock({ $0 }) else { return [] }
            return [
                SetupCheckResult(
                    id: "docker-cli", title: "Docker", ok: false, detail: "missing", action: "install_docker")
            ]
        }
        let engine = makeEngine(host: host)  // probeTTL 0: any rerun is the refresh rule's choice
        for _ in 0..<3 { _ = await engine.healingSignals(now: Date()) }
        XCTAssertEqual(runs.withLock { $0 }, 1, "a healthy checklist is not re-run on an idle fleet")

        let broken = makeEngine(host: host)
        failing.withLock { $0 = true }
        runs.withLock { $0 = 0 }
        for _ in 0..<3 { _ = await broken.healingSignals(now: Date()) }
        XCTAssertEqual(runs.withLock { $0 }, 3, "while it reports problems it is re-run to see them fixed")

        let backoff = makeEngine(host: host)
        failing.withLock { $0 = false }
        runs.withLock { $0 = 0 }
        _ = await backoff.healingSignals(now: Date())
        backoff.noteSpawnFailure(runtime: .docker, reason: "exit 1")
        backoff.noteSpawnFailure(runtime: .docker, reason: "exit 1")
        _ = await backoff.healingSignals(now: Date())
        XCTAssertEqual(runs.withLock { $0 }, 2, "runners failing to start re-run it to learn why")
    }

    func testTartChecksOnlyCountWhenTheFleetRunsTart() async {
        var host = HealingHostActions.inert
        host.setupChecks = { _ in
            [SetupCheckResult(id: "tart", title: "Tart", ok: false, detail: "not installed", action: "install_tart")]
        }
        let tartFleet = makeEngine(host: host)
        let tartSignals = await tartFleet.healingSignals(now: Date())
        XCTAssertEqual(tartSignals.map(\.subject), ["tart"])

        var docker = makeTestConfig()
        docker.docker = KinhinConfig.DockerForgeConfig(image: "kinhin-ci-linux")
        let dockerFleet = makeEngine(config: docker, host: host)
        XCTAssertFalse(dockerFleet.tartInUse)
        let dockerSignals = await dockerFleet.healingSignals(now: Date())
        XCTAssertTrue(dockerSignals.isEmpty, "a Docker fleet is not asked to install tart")
    }

    // MARK: - Fixes

    func testManualFixesAreNeverPerformed() async {
        let engine = makeEngine()
        for kind in Remediation.Kind.allCases where kind.tier == .manual {
            do {
                _ = try await engine.perform(Remediation(kind, subject: "x"))
                XCTFail("\(kind) ran")
            } catch {}
        }
    }

    func testTheJournalSurvivesARestart() async throws {
        let store = makeTestStore()
        let first = makeEngine(store: store)
        first.store.upsert(warmRecord("kinhin-1700000000-aaaa0007"))
        await first.sweepUnwatchedRecords()
        await first.settleDeletes()

        let second = makeEngine(store: FleetStore(directory: store.directory))
        let events = second.healing.snapshot(advisorName: nil).events
        XCTAssertEqual(events.first?.remediation?.kind, .recycleInstance)
    }

    func testFleetStatusCarriesTheSnapshot() async throws {
        let engine = makeEngine()
        engine.store.upsert(warmRecord("kinhin-1700000000-aaaa0008"))
        await engine.sweepUnwatchedRecords()
        await engine.healing.pass(actions: engine)

        let status = await engine.status(includeUsage: false)
        let decoded = try JSONDecoder().decode(FleetStatus.self, from: JSONEncoder().encode(status))
        XCTAssertEqual(decoded.healing?.events.count, 1)
    }

    func testAStatusFromAnOlderDaemonDecodesWithoutHealing() throws {
        var status = FleetStatus()
        status.healing = nil
        let decoded = try JSONDecoder().decode(FleetStatus.self, from: JSONEncoder().encode(status))
        XCTAssertNil(decoded.healing)
    }
}
