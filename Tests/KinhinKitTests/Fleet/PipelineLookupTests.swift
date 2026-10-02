import XCTest

@testable import KinhinKit
@testable import KinhinTestSupport

/// The engine's per-VM pipeline lookup and its daemon RPC.
final class PipelineLookupTests: XCTestCase {
    private func makeEngine(github: FakeGitHub) -> FleetEngine {
        FleetEngine(
            config: makeTestConfig(), github: github, tart: FakeTart(), store: makeTestStore(), ssh: FakeSSH(),
            host: testHost)
    }

    private func busyRecord(_ id: String = "kinhin-vm-1") -> VMRecord {
        var record = VMRecord(id: id, phase: .busy)
        record.platform = "github"
        record.job = "build"
        return record
    }

    private let sample = PipelineDetail(
        forge: .github, title: "CI", state: .running,
        jobs: [PipelineJob(id: "1", name: "build", state: .running, isCurrent: true)])

    func testUnknownVMThrows() async {
        let engine = makeEngine(github: FakeGitHub())
        do {
            _ = try await engine.pipelineDetail(vmID: "kinhin-nope")
            XCTFail("expected unknownVM")
        } catch EngineError.unknownVM {
        } catch {
            XCTFail("wrong error: \(error)")
        }
    }

    func testIdleVMHasNoPipelineAndAsksNoForge() async throws {
        let github = FakeGitHub()
        github.pipeline = sample
        let engine = makeEngine(github: github)
        var idle = VMRecord(id: "kinhin-vm-2", phase: .ready)
        idle.platform = "github"
        engine.store.upsert(idle)
        let detail = try await engine.pipelineDetail(vmID: "kinhin-vm-2")
        XCTAssertNil(detail)
        XCTAssertTrue(github.pipelineRunnerNames.isEmpty)
    }

    func testBusyVMAsksTheForgeByRunnerNameAndCaches() async throws {
        let github = FakeGitHub()
        github.pipeline = sample
        let engine = makeEngine(github: github)
        engine.store.upsert(busyRecord())

        let first = try await engine.pipelineDetail(vmID: "kinhin-vm-1")
        XCTAssertEqual(first, sample)
        XCTAssertEqual(github.pipelineRunnerNames, ["kinhin-vm-1"])
        let second = try await engine.pipelineDetail(vmID: "kinhin-vm-1")
        XCTAssertEqual(second, sample)
        XCTAssertEqual(github.pipelineRunnerNames.count, 1, "a repeat inside the TTL costs no forge call")
    }

    func testRPCReturnsThePipelineOrAnEmptyOK() async throws {
        let github = FakeGitHub()
        let engine = makeEngine(github: github)
        engine.store.upsert(busyRecord())
        let payload = try JSONEncoder().encode(Daemon.VMDeleteRequest(id: "kinhin-vm-1"))

        let none = await Daemon.handle(RPCRequest(id: 1, method: .pipelineDetail, payload: payload), engine: engine)
        XCTAssertTrue(none.ok)
        XCTAssertNil(none.payload, "no running job is an ok response with no payload")

        github.pipeline = sample
        engine.pipelineCache.store(nil, for: "kinhin-vm-1", now: .distantPast)  // let the cached miss expire
        let some = await Daemon.handle(RPCRequest(id: 2, method: .pipelineDetail, payload: payload), engine: engine)
        let decoded = try JSONDecoder().decode(PipelineDetail.self, from: XCTUnwrap(some.payload))
        XCTAssertEqual(decoded.title, "CI")

        let bad = await Daemon.handle(
            RPCRequest(id: 3, method: .pipelineDetail, payload: Data("{}".utf8)), engine: engine)
        XCTAssertFalse(bad.ok)
    }
}

/// The engine's per-step output lookup and its daemon RPC.
final class PipelineLogLookupTests: XCTestCase {
    private func makeEngine(github: FakeGitHub) -> FleetEngine {
        FleetEngine(
            config: makeTestConfig(), github: github, tart: FakeTart(), store: makeTestStore(), ssh: FakeSSH(),
            host: testHost)
    }

    private func setUpBusyVM(_ github: FakeGitHub) -> FleetEngine {
        let steps = [
            PipelineStep(name: "Checkout", state: .succeeded, startedAt: PipelineParsing.date("2026-10-02T10:00:01Z")),
            PipelineStep(name: "Test", state: .running, startedAt: PipelineParsing.date("2026-10-02T10:00:05Z")),
        ]
        github.pipeline = PipelineDetail(
            forge: .github, title: "CI", state: .running,
            jobs: [
                PipelineJob(
                    id: "11", name: "build", state: .running, steps: steps, isCurrent: true,
                    logRef: "acme/widgets|11")
            ])
        github.jobLogs["acme/widgets|11"] = """
            2026-10-02T10:00:01.1000000Z checkout output
            2026-10-02T10:00:06.0000000Z test output
            """
        let engine = makeEngine(github: github)
        var record = VMRecord(id: "kinhin-vm-1", phase: .busy)
        record.platform = "github"
        record.job = "build"
        engine.store.upsert(record)
        return engine
    }

    func testStepOutputIsSlicedFromTheJobLog() async throws {
        let engine = setUpBusyVM(FakeGitHub())
        let step = try await engine.pipelineLog(vmID: "kinhin-vm-1", jobID: "11", stepIndex: 1)
        XCTAssertEqual(step?.text, "2026-10-02T10:00:06.0000000Z test output")
        let job = try await engine.pipelineLog(vmID: "kinhin-vm-1", jobID: "11", stepIndex: nil)
        XCTAssertEqual(job?.scope, .job)
    }

    func testUnknownJobStepAndVMThrow() async throws {
        let engine = setUpBusyVM(FakeGitHub())
        do {
            _ = try await engine.pipelineLog(vmID: "kinhin-vm-1", jobID: "nope", stepIndex: nil)
            XCTFail("expected unknownPipelineJob")
        } catch EngineError.unknownPipelineJob {}
        do {
            _ = try await engine.pipelineLog(vmID: "kinhin-vm-1", jobID: "11", stepIndex: 9)
            XCTFail("expected unknownPipelineJob")
        } catch EngineError.unknownPipelineJob {}
        do {
            _ = try await engine.pipelineLog(vmID: "kinhin-gone", jobID: "11", stepIndex: nil)
            XCTFail("expected unknownVM")
        } catch EngineError.unknownVM {}
    }

    func testRPCRoundTrip() async throws {
        let engine = setUpBusyVM(FakeGitHub())
        let ask = try JSONEncoder().encode(Daemon.PipelineLogRequest(id: "kinhin-vm-1", jobID: "11", stepIndex: 0))
        let response = await Daemon.handle(RPCRequest(id: 1, method: .pipelineLog, payload: ask), engine: engine)
        XCTAssertTrue(response.ok)
        let log = try JSONDecoder().decode(PipelineLog.self, from: XCTUnwrap(response.payload))
        XCTAssertTrue(log.text.contains("checkout output"))
        XCTAssertFalse(log.text.contains("test output"))

        let bad = await Daemon.handle(RPCRequest(id: 2, method: .pipelineLog, payload: Data("{}".utf8)), engine: engine)
        XCTAssertFalse(bad.ok)
    }
}
