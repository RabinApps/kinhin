import XCTest

@testable import KinhinKit
@testable import KinhinTestSupport
@testable import kinhin_app

/// Who owns the exporters in the app: the app's own `TelemetryService` only while it runs the engine in-process, the
/// daemon otherwise. The app reads the daemon's status but never starts exporters beside it, applies a telemetry edit
/// without restarting the engine, and flushes on quit only when it owns them (bounded).
@MainActor
final class TelemetryOwnershipTests: XCTestCase {
    private final class Calls: Sendable {
        private let applied = Locked<[KinhinConfig.TelemetryConfig]>([])
        private let flushes = Locked(0)
        private let ownReads = Locked(0)
        private let daemonReads = Locked(0)
        var appliedConfigs: [KinhinConfig.TelemetryConfig] { applied.withLock { $0 } }
        var flushCount: Int { flushes.withLock { $0 } }
        var ownReadCount: Int { ownReads.withLock { $0 } }
        var daemonReadCount: Int { daemonReads.withLock { $0 } }
        func apply(_ config: KinhinConfig.TelemetryConfig) { applied.withLock { $0.append(config) } }
        func flush() { flushes.withLock { $0 += 1 } }
        func ownRead() { ownReads.withLock { $0 += 1 } }
        func daemonRead() { daemonReads.withLock { $0 += 1 } }
    }

    private let host = HostResources(logicalCores: 12, memoryGB: 32, freeDiskGB: 200, arm64: true)
    private var dir: URL!
    private var url: URL!
    private var fleet: FleetController!
    private var calls: Calls!

    private nonisolated static let own = TelemetryStatus(
        enabled: true, signals: ["metrics"], otlpProtocol: "http/protobuf", endpoints: ["metrics": "http://own:4318"],
        prometheus: nil, jobAttributes: [], startedAt: nil, exportFailures: 0, lastFailureAt: nil, lastFailure: nil)
    private nonisolated static let daemon = TelemetryStatus(
        enabled: true, signals: ["traces"], otlpProtocol: "grpc", endpoints: ["traces": "http://daemon:4317"],
        prometheus: "127.0.0.1:9464", jobAttributes: [], startedAt: nil, exportFailures: 0, lastFailureAt: nil,
        lastFailure: nil)

    override func setUp() async throws {
        try await super.setUp()
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("kinhin-telemetry-own-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        url = dir.appendingPathComponent("config.yaml")
        try yaml(telemetry: nil).write(to: url, atomically: true, encoding: .utf8)
        calls = Calls()
        fleet = FleetController()
        fleet.environment.configURL = url
        fleet.environment.hostSnapshot = { [host] in host }
        fleet.environment.daemonProbe = { false }
        let calls = calls!
        fleet.environment.applyTelemetry = { calls.apply($0) }
        fleet.environment.shutdownTelemetry = { calls.flush() }
        fleet.environment.ownTelemetryStatus = {
            calls.ownRead()
            return Self.own
        }
        fleet.environment.daemonTelemetryStatus = {
            calls.daemonRead()
            return Self.daemon
        }
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: dir)
        fleet = nil
        try await super.tearDown()
    }

    private func yaml(telemetry: String?) -> String {
        var text = """
            accounts:
              - name: github
                forge: github
                scope: "acme/widgets"
            labels: ["kinhin"]
            vm:
              cpu: 4
              memory_gb: 8
            image: "tahoe-base"
            """
        if let telemetry { text += "\n" + telemetry }
        return text
    }

    private func installEngine() throws -> FleetEngine {
        let engine = FleetEngine(
            config: try ConfigLoader.parse(yaml(telemetry: nil)), github: FakeGitHub(), tart: FakeTart(),
            store: makeTestStore(), ssh: FakeSSH(), host: host,
            dependencies: .init(tokenLoader: { _, _ in "test-token" }, lifecycleDrainTimeout: .seconds(5)))
        fleet.service = FleetBackend.inProcess(engine)
        return engine
    }

    private func attachDaemon() {
        fleet.backend = .daemon(RPCClient(socketURL: dir.appendingPathComponent("none.sock")))
    }

    // MARK: - Where the status comes from

    func testInProcessEngineReadsItsOwnService() async throws {
        _ = try installEngine()
        let reading = await fleet.readTelemetry()
        XCTAssertEqual(reading, .inProcess(Self.own))
        XCTAssertEqual(calls.daemonReadCount, 0, "an app with its own engine never asks a daemon")
    }

    func testDaemonBackendAsksTheDaemonAndNeverTheOwnService() async {
        attachDaemon()
        let reading = await fleet.readTelemetry()
        XCTAssertEqual(reading, .daemon(Self.daemon))
        XCTAssertEqual(calls.ownReadCount, 0, "the daemon exports; the app has nothing of its own to report")
    }

    func testDaemonThatCannotAnswerIsReportedNotHidden() async {
        attachDaemon()
        fleet.environment.daemonTelemetryStatus = { throw RPCError.rejected("this daemon predates telemetry status") }
        guard case .daemonUnreachable(let why) = await fleet.readTelemetry() else {
            return XCTFail("expected a failure")
        }
        XCTAssertTrue(why.contains("predates"), why)
    }

    func testNoFleetAsksNobody() async {
        var reading = await fleet.readTelemetry()
        XCTAssertEqual(reading, .noFleet)
        fleet.service = FakeFleetServing()
        reading = await fleet.readTelemetry()
        XCTAssertEqual(reading, .noFleet)
        XCTAssertEqual(calls.ownReadCount + calls.daemonReadCount, 0)
    }

    // MARK: - Applying an edit

    func testTelemetryEditAppliesInPlaceWithoutRestartingTheInProcessEngine() async throws {
        let engine = try installEngine()
        fleet.environment.makeEngine = { _, _ in
            XCTFail("a telemetry edit must not rebuild the engine")
            return engine
        }
        try yaml(telemetry: "telemetry:\n  enabled: true\n  prometheus_listen: \"127.0.0.1:9464\"")
            .write(to: url, atomically: true, encoding: .utf8)

        await fleet.applyConfigToEngine()

        XCTAssertTrue(fleet.engine === engine)
        XCTAssertEqual(calls.appliedConfigs.map(\.enabled), [true])
        XCTAssertEqual(calls.appliedConfigs.first?.prometheusListen, "127.0.0.1:9464")
    }

    func testAnAppAttachedToADaemonStartsNoExporters() async throws {
        attachDaemon()
        try yaml(telemetry: "telemetry:\n  enabled: true").write(to: url, atomically: true, encoding: .utf8)

        await fleet.applyConfigToEngine()  // the daemon is unreachable here; that is not what this checks

        XCTAssertTrue(calls.appliedConfigs.isEmpty, "the daemon applies the edit; the app creates no exporters")
    }

    // MARK: - Quit

    func testQuitFlushesTelemetryAfterStoppingTheInProcessEngine() async throws {
        _ = try installEngine()
        await fleet.shutdown()
        XCTAssertEqual(calls.flushCount, 1)
    }

    func testQuitLeavesADaemonsExportersAlone() async {
        attachDaemon()
        await fleet.shutdown()
        XCTAssertEqual(calls.flushCount, 0)
    }

    func testQuitWithoutAFleetFlushesNothing() async {
        await fleet.shutdown()
        XCTAssertEqual(calls.flushCount, 0)
    }

    func testAHungCollectorCannotHoldUpQuit() async throws {
        _ = try installEngine()
        fleet.environment.shutdownTelemetry = { try? await Task.sleep(for: .seconds(30)) }
        let started = ContinuousClock.now
        await fleet.shutdown(telemetryTimeout: .milliseconds(100))
        XCTAssertLessThan(ContinuousClock.now - started, .seconds(5), "the flush is bounded")
    }
}
