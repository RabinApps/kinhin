import KinhinKit
import XCTest

@testable import kinhin

/// `RunCommands.control` drives the shared `FleetServing` seam (the same type
/// the app uses) instead of its own RPC switch.
final class RunControlTests: XCTestCase {
    private final class Recorder: FleetServing, @unchecked Sendable {
        var calls: [String] = []
        var failure: Error?
        func status() async throws -> FleetStatus { throw EngineError.fleetNotSetUp }
        func start() async throws { calls.append("start") }
        func stop() async throws {
            calls.append("stop")
            if let failure { throw failure }
        }
        func setPaused(_ paused: Bool) async throws {
            calls.append(paused ? "pause" : "resume")
            if let failure { throw failure }
        }
        func deleteVM(id: String) async throws {}
        func pipelineDetail(vmID: String) async throws -> PipelineDetail? { nil }
        func pipelineLog(vmID: String, jobID: String, stepIndex: Int?) async throws -> PipelineLog? { nil }
        func rotate(_ target: CredentialRotation.Target, token: String) async throws {}
        func requeueQueuedJobs(for forge: ForgeID) async throws {}
        func skipQueuedJobs(for forge: ForgeID) async throws {}
        var logName: String { "recorder" }
    }

    func testStopPauseResumeCallTheBackendAndReturnTheCLILine() async throws {
        let backend = Recorder()
        let stop = try await RunCommands.control(.stop, on: backend)
        let pause = try await RunCommands.control(.pause, on: backend)
        let resume = try await RunCommands.control(.resume, on: backend)
        XCTAssertEqual(backend.calls, ["stop", "pause", "resume"])
        XCTAssertEqual([stop, pause, resume], ["daemon fleet stopped", "fleet paused", "fleet resumed"])
    }

    func testDaemonRefusalIsARuntimeControlFailureWithTheRawReason() async {
        let backend = Recorder()
        backend.failure = RPCError.rejected("boom")
        do {
            _ = try await RunCommands.control(.pause, on: backend)
            XCTFail("expected a failure")
        } catch let error as RunCommands.ControlFailure {
            XCTAssertEqual(error.message, "boom")
            XCTAssertEqual(error.exit, .runtime)
        } catch {
            XCTFail("unexpected \(error)")
        }
    }

    // MARK: - Status extras

    private struct TartBroke: LocalizedError {
        var errorDescription: String? { "tart list failed: boom" }
    }

    func testOrphanScanReportsAFailingTartInsteadOfNoOrphans() async throws {
        let scan = try await RunCommands.orphanScan { throw TartBroke() }
        XCTAssertEqual(scan.lines, [])
        XCTAssertEqual(scan.warning, "could not check for orphaned VMs: tart list failed: boom")
    }

    func testOrphanScanListsOnlyKinhinVMs() async throws {
        let scan = try await RunCommands.orphanScan {
            [
                TartVM(name: "kinhin-1", source: "local", status: "running"),
                TartVM(name: "tahoe-base", source: "local", status: "stopped"),
            ]
        }
        XCTAssertEqual(scan.lines, ["orphaned kinhin VMs (daemon not managing them):", "  kinhin-1  running"])
        XCTAssertNil(scan.warning)
        let none = try await RunCommands.orphanScan(nil)
        XCTAssertEqual(none.lines, [])
        XCTAssertNil(none.warning, "no tart at all means nothing can be orphaned")
    }

    func testOrphanScanLetsCancellationThrough() async {
        do {
            _ = try await RunCommands.orphanScan { throw CancellationError() }
            XCTFail("cancellation must propagate")
        } catch {
            XCTAssertTrue(error is CancellationError)
        }
    }

    func testWatchFrameTellsADaemonErrorFromNoDaemon() {
        XCTAssertEqual(
            RunCommands.watchFrame(.failure(RPCError.connectionFailed("/tmp/s"))), "daemon not running…")
        let frame = RunCommands.watchFrame(.failure(RPCError.timeout))
        XCTAssertTrue(frame.hasPrefix("daemon error: daemon did not answer in time"), frame)
    }
}
