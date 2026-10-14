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
    private var alerts: [(title: String, body: String)] = []
    private final class AnswerBox: Sendable {
        let value = Locked<Result<String?, Error>>(.success("ghp_test"))
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
        // Never the developer's real daemon: a running fleet on this Mac would
        // otherwise become the backend under test.
        fleet.environment.daemonProbe = { false }
        let answer = tokenAnswerBox
        fleet.environment.engineToken = { _ in try answer.value.withLock { $0 }.get() }
        alerts = []
        AlertKit.runModal = { [unowned self] alert in
            alerts.append((alert.messageText, alert.informativeText))
            return .alertFirstButtonReturn
        }
    }

    override func tearDown() async throws {
        AlertKit.runModal = { $0.runModal() }
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
    private var pushProblem: String? { fleet.problems[.configPush] }

    /// Main-actor poll (the shared `waitUntil` is nonisolated, and this state is the controller's).
    private func waitUntil(_ message: String, _ condition: () -> Bool) async {
        let deadline = ContinuousClock.now + .seconds(5)
        while !condition() {
            if ContinuousClock.now > deadline { return XCTFail("timed out: \(message)") }
            try? await Task.sleep(for: .milliseconds(10))
        }
    }

    /// The user-visible state after a push that didn't apply: the status-line
    /// problem names the reason and says the old config is still running.
    private func assertNotApplied(
        mentioning reason: String, file: StaticString = #filePath, line: UInt = #line
    ) {
        guard let problem = pushProblem else { return XCTFail("no status-line problem", file: file, line: line) }
        XCTAssertTrue(
            problem.hasPrefix("Your config change was saved but couldn't be applied: "), problem, file: file, line: line
        )
        XCTAssertTrue(problem.contains(reason), "\(problem) should name \(reason)", file: file, line: line)
        XCTAssertTrue(
            problem.hasSuffix("The fleet is still using the previous config."), problem, file: file, line: line)
    }
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
        assertNotApplied(mentioning: "config must be Mapping")  // the parse error is shown, not only logged
        XCTAssertTrue(alerts.isEmpty, "a push nobody asked to alert on stays on the status line")
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
        assertNotApplied(mentioning: "the forge token couldn't be read from the Keychain")
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
        assertNotApplied(mentioning: "the forge token is missing from the Keychain")
    }

    func testFactoryFailureKeepsTheCurrentEngine() async throws {
        struct TartMissing: LocalizedError { var errorDescription: String? { "tart is not installed" } }
        let engine = try install { _ in throw TartMissing() }
        try write(yaml(vmCPU: 6))
        await fleet.applyConfigToEngine()
        XCTAssertTrue(currentEngine === engine)
        XCTAssertEqual(buildCount, 1)
        assertNotApplied(mentioning: "tart is not installed")
    }

    func testAFailedSaveFromTheWindowAlertsAndASuccessfulOneClearsTheProblem() async throws {
        struct TartMissing: LocalizedError { var errorDescription: String? { "tart is not installed" } }
        var fail = true
        _ = try install { config in
            if fail { throw TartMissing() }
            return self.makeEngine(config)
        }
        fleet.configPush.delay = .milliseconds(10)
        try write(yaml(vmCPU: 6))

        fleet.pushConfigToEngine()  // the window's save path
        await waitUntil("alerted") { alerts.count == 1 }
        XCTAssertEqual(alerts.first?.title, "Config change not applied")
        XCTAssertEqual(alerts.first?.body, pushProblem, "the alert and the status line say the same thing")
        assertNotApplied(mentioning: "tart is not installed")

        fail = false
        try write(yaml(vmCPU: 8))
        fleet.pushConfigToEngine()
        await waitUntil("problem cleared") { pushProblem == nil }
        XCTAssertEqual(currentEngine?.activeConfig.vm.cpuCount, 8)
        XCTAssertEqual(alerts.count, 1, "a push that applied says nothing more")
    }

    func testAFailedPushFromShortcutsStaysOnTheStatusLine() async throws {
        struct TartMissing: Error {}
        _ = try install { _ in throw TartMissing() }
        fleet.configPush.delay = .milliseconds(10)
        try write(yaml(vmCPU: 6))

        fleet.pushConfigToEngine(alertOnFailure: false)
        await waitUntil("flushed") { pushProblem != nil && !fleet.configPush.isScheduled }
        XCTAssertTrue(alerts.isEmpty, "no modal for an edit made from Shortcuts")
    }

    func testCancelledRebuildIsNotAFailure() async throws {
        _ = try install { _ in throw CancellationError() }
        fleet.configPushAlertsOnFailure = true
        try write(yaml(vmCPU: 6))
        await fleet.applyConfigToEngine()
        XCTAssertNil(pushProblem, "cancellation is never shown as a failure")
        XCTAssertTrue(alerts.isEmpty)
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
        assertNotApplied(mentioning: "the fleet engine didn't restart with it")
        await old.stop()
    }

    // MARK: - Daemon backend

    func testDeadDaemonReloadFailureIsShownNotThrown() async {
        let socket = dir.appendingPathComponent("no-daemon.sock")
        fleet.backend = .daemon(RPCClient(socketURL: socket))
        await fleet.applyConfigToEngine()
        XCTAssertNil(fleet.status, "the unreachable daemon reads as no status afterwards")
        assertNotApplied(mentioning: "could not connect to daemon")
    }

    func testNoBackendIsANoOp() async {
        await fleet.applyConfigToEngine()
        XCTAssertNil(fleet.service)
        XCTAssertEqual(buildCount, 0)
        XCTAssertNil(pushProblem)
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
