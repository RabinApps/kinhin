import AppKit
import Synchronization
import XCTest

@testable import KinhinKit
@testable import KinhinTestSupport
@testable import kinhin_app

/// What a config edit does to the running fleet: routing-only edits hot-reload
/// the same engine, shape edits rebuild it (keeping a stopped fleet stopped
/// and a running one running), and every failure leaves the old engine serving.
@MainActor
final class FleetControllerConfigPushTests: XCTestCase {
    private let host = HostResources(logicalCores: 12, memoryGB: 32, freeDiskGB: 200, arm64: true)
    private var dir: URL!
    private var url: URL!
    private var fleet: FleetController!
    private var builds: BuildLog!
    private final class AnswerBox: Sendable {
        let value = Mutex<Result<String?, Error>>(.success("ghp_test"))
    }
    private let tokenAnswerBox = AnswerBox()
    private var tokenAnswer: Result<String?, Error> {
        get { tokenAnswerBox.value.withLock { $0 } }
        set { tokenAnswerBox.value.withLock { $0 = newValue } }
    }

    override func setUp() async throws {
        try await super.setUp()
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("kinhin-cfgpush-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        url = dir.appendingPathComponent("config.yaml")
        try yaml().write(to: url, atomically: true, encoding: .utf8)
        builds = BuildLog()
        tokenAnswer = .success("ghp_test")
        fleet = FleetController()
        fleet.environment.configURL = url
        fleet.environment.hostSnapshot = { [host] in host }
        let answer = tokenAnswerBox
        fleet.environment.engineToken = { _ in try answer.value.withLock { $0 }.get() }
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: dir)
        fleet = nil
        try await super.tearDown()
    }

    // MARK: - Fixtures

    private func yaml(vmCPU: Int = 4, runtimes: String? = nil) -> String {
        var text = """
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
        if let runtimes { text += "\n" + runtimes }
        return text
    }

    private func makeEngine(_ config: KinhinConfig, github: FakeGitHub = FakeGitHub()) -> FleetEngine {
        FleetEngine(
            config: config, github: github, tart: FakeTart(), store: makeTestStore(), ssh: FakeSSH(), host: host,
            // Hermetic: a rebuilt engine's start() must not read the real Keychain.
            dependencies: .init(tokenLoader: { _, _ in "test-token" }, lifecycleDrainTimeout: .seconds(5)))
    }

    /// Installs an engine on the controller; `factory` answers rebuilds.
    private func install(
        vmCPU: Int = 4, factory: @escaping (KinhinConfig) throws -> FleetEngine
    ) throws -> FleetEngine {
        let engine = makeEngine(try ConfigLoader.parse(yaml(vmCPU: vmCPU)))
        fleet.service = FleetBackend.inProcess(engine)
        fleet.environment.makeEngine = { [builds] config, _ in
            builds?.record(config)
            return try factory(config)
        }
        return engine
    }

    private func write(_ text: String) throws {
        try text.write(to: url, atomically: true, encoding: .utf8)
    }

    private var currentEngine: FleetEngine? { fleet.engine }
    private var buildCount: Int { builds?.count ?? 0 }

    // MARK: - Hot reload

    func testRoutingOnlyEditReloadsTheSameEngine() async throws {
        let engine = try install { config in
            XCTFail("routing-only edits must not rebuild"); return self.makeEngine(config)
        }
        try write(
            yaml(runtimes: "runtimes:\n  default: tart\n  routes:\n    - pattern: \"acme/api\"\n      runtime: tart\n"))

        await fleet.applyConfigToEngine()

        XCTAssertTrue(currentEngine === engine, "the same engine keeps serving")
        XCTAssertEqual(buildCount, 0)
        XCTAssertEqual(engine.routing.routes.map(\.pattern), ["acme/api"], "the new routing is live")
    }

    // MARK: - Rebuild

    func testShapeEditWhileStoppedRebuildsAndStaysStopped() async throws {
        var replacement: FleetEngine?
        let old = try install { config in
            let engine = self.makeEngine(config)
            replacement = engine
            return engine
        }
        try write(yaml(vmCPU: 6))

        await fleet.applyConfigToEngine()

        XCTAssertEqual(buildCount, 1)
        XCTAssertTrue(currentEngine === replacement, "the controller now serves the rebuilt engine")
        XCTAssertFalse(currentEngine === old)
        XCTAssertEqual(currentEngine?.activeConfig.vm.cpuCount, 6)
        let status = await replacement!.status()
        XCTAssertFalse(status.running, "a config edit must never start a stopped fleet")
    }

    func testShapeEditWhileRunningResumesAtThePreviousState() async throws {
        var replacement: FleetEngine?
        let old = try install { config in
            let engine = self.makeEngine(config)
            replacement = engine
            return engine
        }
        await old.start()
        await old.setPaused(true)
        try write(yaml(vmCPU: 6))

        await fleet.applyConfigToEngine()

        XCTAssertTrue(currentEngine === replacement)
        let status = await replacement!.status()
        XCTAssertTrue(status.running, "a running fleet is running after the swap")
        XCTAssertTrue(status.paused, "and a paused one stays paused")
        let oldStatus = await old.status()
        XCTAssertFalse(oldStatus.running, "the old engine stopped scaling (detached)")
        await replacement?.stop()
    }

    // MARK: - Failures keep the old engine serving

    func testUnreadableConfigKeepsTheCurrentEngine() async throws {
        let engine = try install { config in
            XCTFail("nothing to rebuild from"); return self.makeEngine(config)
        }
        try write("- just\n- a list\n")
        await fleet.applyConfigToEngine()
        XCTAssertTrue(currentEngine === engine)
        XCTAssertEqual(buildCount, 0)
    }

    func testKeychainFailureKeepsTheCurrentEngine() async throws {
        struct KeychainDown: Error {}
        let engine = try install { config in
            XCTFail("no token, no rebuild"); return self.makeEngine(config)
        }
        tokenAnswer = .failure(KeychainDown())
        try write(yaml(vmCPU: 6))
        await fleet.applyConfigToEngine()
        XCTAssertTrue(currentEngine === engine)
        XCTAssertEqual(buildCount, 0)
    }

    func testMissingTokenKeepsTheCurrentEngine() async throws {
        let engine = try install { config in
            XCTFail("no token, no rebuild"); return self.makeEngine(config)
        }
        tokenAnswer = .success(nil)
        try write(yaml(vmCPU: 6))
        await fleet.applyConfigToEngine()
        XCTAssertTrue(currentEngine === engine)
        XCTAssertEqual(buildCount, 0)
    }

    func testFactoryFailureKeepsTheCurrentEngine() async throws {
        struct TartMissing: Error {}
        let engine = try install { _ in throw TartMissing() }
        try write(yaml(vmCPU: 6))
        await fleet.applyConfigToEngine()
        XCTAssertTrue(currentEngine === engine)
        XCTAssertEqual(buildCount, 1)
    }

    func testReplacementThatCannotStartKeepsTheRunningEngine() async throws {
        let old = try install { config in
            let github = FakeGitHub()
            github.permissionDenied = true  // the new token can't manage runners
            return self.makeEngine(config, github: github)
        }
        await old.start()
        try write(yaml(vmCPU: 6))

        await fleet.applyConfigToEngine()

        XCTAssertTrue(currentEngine === old, "a dead replacement must not displace a running fleet")
        let status = await old.status()
        XCTAssertTrue(status.running)
        await old.stop()
    }

    // MARK: - Daemon backend

    func testDeadDaemonReloadFailureIsLoggedNotThrown() async {
        let socket = dir.appendingPathComponent("no-daemon.sock")
        fleet.backend = .daemon(RPCClient(socketURL: socket))
        await fleet.applyConfigToEngine()
        XCTAssertNil(fleet.status, "the unreachable daemon reads as no status afterwards")
    }

    func testNoBackendIsANoOp() async {
        await fleet.applyConfigToEngine()
        XCTAssertNil(fleet.service)
        XCTAssertEqual(buildCount, 0)
    }

    // MARK: - Shutdown and auto-start

    func testShutdownStopsARunningInProcessEngineAndPolling() async throws {
        let engine = try install { config in self.makeEngine(config) }
        await engine.start()
        fleet.startPolling(every: .milliseconds(20))

        await fleet.shutdown(timeout: .seconds(10))

        let status = await engine.status()
        XCTAssertFalse(status.running, "quitting stops the in-process engine")
    }

    func testShutdownLeavesADaemonFleetAlone() async {
        let fake = FakeFleetServing(FleetStatus(running: true))
        fleet.service = fake
        await fleet.shutdown(timeout: .seconds(1))
        XCTAssertFalse(fake.calls.contains("stop"), "the daemon owns its own lifecycle")
    }

    func testAutoStartRunsThroughPerformSoTheStatusItemShowsStarting() async throws {
        let engine = try install { config in self.makeEngine(config) }
        let delegate = AppDelegate()
        delegate.fleet.service = FleetBackend.inProcess(engine)

        delegate.autoStartFleetIfEnabled(enabled: true)
        XCTAssertNotNil(delegate.fleet.engine)
        let deadline = ContinuousClock.now + .seconds(5)
        while delegate.fleet.status?.running != true, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(delegate.fleet.status?.running, true)
        XCTAssertNil(delegate.fleet.pendingFleetAction)
        await engine.stop()
    }

    func testAutoStartDoesNothingWhenDisabledOrDaemonOwned() async {
        let delegate = AppDelegate()
        let fake = FakeFleetServing()
        delegate.fleet.service = fake
        delegate.autoStartFleetIfEnabled(enabled: true)  // not an in-process engine
        delegate.autoStartFleetIfEnabled(enabled: false)
        try? await Task.sleep(for: .milliseconds(50))
        XCTAssertFalse(fake.calls.contains("start"))
    }

    func testQuitWithoutAnInProcessEngineTerminatesImmediately() {
        let delegate = AppDelegate()
        XCTAssertEqual(delegate.applicationShouldTerminate(NSApplication.shared), .terminateNow)
        delegate.fleet.service = FakeFleetServing()
        XCTAssertEqual(
            delegate.applicationShouldTerminate(NSApplication.shared), .terminateNow, "daemon fleets aren't ours")
    }

    // MARK: - Auto-resume policy

    func testAutoResumePolicyWritesTheConfigAndPushesIt() async throws {
        var flushes = 0
        fleet.configPush.delay = .milliseconds(10)
        fleet.configPush.flush = { flushes += 1 }

        try await fleet.setAutoResumePolicy(true)

        XCTAssertEqual(try ConfigStore.snapshot(at: url)?.autoResume, true)
        let deadline = ContinuousClock.now + .seconds(5)
        while flushes == 0, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertEqual(flushes, 1, "the edit reaches the engine")
    }

    func testAutoResumePolicyThrowsWhenTheConfigIsMissingAndPushesNothing() async {
        try? FileManager.default.removeItem(at: url)
        var flushes = 0
        fleet.configPush.delay = .milliseconds(10)
        fleet.configPush.flush = { flushes += 1 }
        do {
            try await fleet.setAutoResumePolicy(true)
            XCTFail("a missing config must fail the intent")
        } catch {
            try? await Task.sleep(for: .milliseconds(80))
            XCTAssertEqual(flushes, 0, "nothing was written, so nothing is pushed")
        }
    }
}

/// Records the configs a rebuild was asked for (the factory runs off-actor).
private final class BuildLog: Sendable {
    private let configs = Mutex<[KinhinConfig]>([])
    func record(_ config: KinhinConfig) { configs.withLock { $0.append(config) } }
    var count: Int { configs.withLock { $0.count } }
}
