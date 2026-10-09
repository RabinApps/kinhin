import XCTest

@testable import KinhinKit
@testable import KinhinTestSupport

/// `bench_start` and `bench_status` through `Daemon.handle`.
final class BenchmarkRPCTests: XCTestCase {
    private func makeEngine() -> FleetEngine {
        FleetEngine(
            config: makeTestConfig(), github: FakeGitHub(), tart: FakeTart(), store: makeTestStore(), ssh: FakeSSH(),
            host: testHost, dependencies: .init(tokenLoader: { _, _ in "test-token" }))
    }

    private func handle(_ request: RPCRequest, registry: BenchmarkRegistry) async -> RPCResponse {
        await Daemon.handle(request, engineRef: Daemon.EngineRef(makeEngine()), benchmarks: registry)
    }

    func testStartAnswersWithARunIDAndStatusFollowsIt() async throws {
        let registry = BenchmarkRegistry()
        // tart is not installed here (or has no image): the run fails fast, which is what a status poll must show.
        let payload = try JSONEncoder().encode(BenchmarkOptions(suites: [.boot], runtimes: [.tart]))
        let start = await handle(RPCRequest(id: 1, method: .benchStart, payload: payload), registry: registry)
        XCTAssertTrue(start.ok, start.error ?? "")
        let reply = try JSONDecoder().decode(Daemon.BenchStartReply.self, from: XCTUnwrap(start.payload))
        XCTAssertTrue(reply.runID.hasPrefix("bench-"))
        await registry.wait(runID: reply.runID)

        let ask = try JSONEncoder().encode(Daemon.BenchStatusRequest(runID: reply.runID))
        let status = await handle(RPCRequest(id: 2, method: .benchStatus, payload: ask), registry: registry)
        XCTAssertTrue(status.ok, status.error ?? "")
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let run = try decoder.decode(BenchmarkRunStatus.self, from: XCTUnwrap(status.payload))
        XCTAssertEqual(run.runID, reply.runID)
        XCTAssertTrue(run.state.isFinal)
    }

    func testStatusWithNoPayloadAnswersTheLatestRun() async throws {
        let registry = BenchmarkRegistry()
        let none = await handle(RPCRequest(id: 3, method: .benchStatus), registry: registry)
        XCTAssertFalse(none.ok, "no run has started")
        XCTAssertTrue(none.error?.contains("no benchmark run") == true, none.error ?? "")
    }

    func testStartRejectsAMalformedPayloadAndInvalidOptions() async throws {
        let registry = BenchmarkRegistry()
        let malformed = await handle(
            RPCRequest(id: 4, method: .benchStart, payload: Data(#"{"nope":1}"#.utf8)), registry: registry)
        XCTAssertFalse(malformed.ok)
        let invalid = await handle(
            RPCRequest(id: 5, method: .benchStart, payload: try JSONEncoder().encode(BenchmarkOptions(iterations: 99))),
            registry: registry)
        XCTAssertFalse(invalid.ok)
        XCTAssertTrue(invalid.error?.contains("--iterations") == true, invalid.error ?? "")
        XCTAssertNil(registry.status(runID: nil), "nothing started")
    }

    func testStartIsSerializedThroughTheFleetGateAndStatusIsNot() {
        XCTAssertTrue(RPCMethod.benchStart.mutatesFleet)
        XCTAssertFalse(RPCMethod.benchStatus.mutatesFleet)
        XCTAssertEqual(RPCMethod.benchStart.rawValue, "bench_start")
        XCTAssertEqual(RPCMethod.benchStatus.rawValue, "bench_status")
    }

    func testTheEngineBuildsABenchmarkEnvironmentThatPausesItself() async throws {
        let engine = makeEngine()
        let env = engine.benchmarkEnvironment(root: FileManager.default.temporaryDirectory)
        let fleet = try XCTUnwrap(env.fleet)
        try await fleet.setPaused(true)
        XCTAssertTrue(engine.paused)
        try await fleet.setPaused(false)
        XCTAssertFalse(engine.paused)
        let impact = try await fleet.impact()
        XCTAssertEqual(impact.active, 0)
    }

    func testFleetServingDefaultsRefuseBenchmarks() async {
        struct Bare: FleetServing {
            func status() async throws -> FleetStatus { FleetStatus() }
            func start() async throws {}
            func stop() async throws {}
            func setPaused(_ paused: Bool) async throws {}
            func deleteVM(id: String) async throws {}
            func pipelineDetail(vmID: String) async throws -> PipelineDetail? { nil }
            func pipelineLog(vmID: String, jobID: String, stepIndex: Int?) async throws -> PipelineLog? { nil }
            func rotate(_ target: CredentialRotation.Target, token: String) async throws {}
            func requeueQueuedJobs(for forge: ForgeID) async throws {}
            func skipQueuedJobs(for forge: ForgeID) async throws {}
            var logName: String { "bare" }
        }
        do {
            _ = try await Bare().benchStart(BenchmarkOptions())
            XCTFail("expected unsupported")
        } catch BenchmarkError.unsupported {
        } catch {
            XCTFail("\(error)")
        }
    }
}
