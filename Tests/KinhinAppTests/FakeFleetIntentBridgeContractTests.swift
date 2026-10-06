import XCTest

@testable import KinhinKit
@testable import kinhin_app

/// Contract for `FakeFleetIntentBridge` as a `FleetIntentBridge`: driven
/// against the real `AppFleetIntentBridge` over an equivalent backend, the
/// intents must observe the same answers — status passing through
/// unchanged, start/stop leaving the fleet running/stopped, pause flipping
/// the flag, a deleted record leaving the others, and the same errors the
/// production bridge raises (`fleetNotSetUp` with no controller, the
/// backend's own failure on a command). `FleetIntentBridgeTests` pins the
/// real bridge's routing; this file pins the fake to it. Delete mirrors the
/// backend's id validation: an id that is not a present `kinhin-*` record
/// throws `EngineError.unknownVM` on both bridges, and the fake's
/// `appliesDelete` stays opt-in to model the async teardown where the
/// follow-up poll still lists the VM (`FleetIntentTests` pins that dialog).
/// Excluded: `autoResumeEnabled` (the production bridge reads the real user
/// config, which tests must not touch) and `doctor` (the fake traps it —
/// intents never reach it in tests).
@MainActor
final class FakeFleetIntentBridgeContractTests: XCTestCase {
    /// A controller whose backend answers with the given status.
    private func makeReal(_ status: FleetStatus = FleetStatus()) -> (AppFleetIntentBridge, FakeFleetServing) {
        let backend = FakeFleetServing(status)
        let controller = FleetController()
        controller.service = backend
        return (AppFleetIntentBridge(controller: controller), backend)
    }

    private func makeStatus(_ ids: [String]) -> FleetStatus {
        FleetStatus(
            records: ids.map { id in
                var record = VMRecord(id: id, phase: .ready)
                record.createdAt = Date()
                return record
            })
    }

    /// The id out of an `EngineError.unknownVM` (nil for any other error).
    private func unknownVMID(_ error: Error?) -> String? {
        guard case EngineError.unknownVM(let id)? = error as? EngineError else { return nil }
        return id
    }

    /// The first error `op` throws (nil when it succeeds).
    private func firstError(_ op: () async throws -> Void) async -> Error? {
        do {
            try await op()
            return nil
        } catch {
            return error
        }
    }

    // MARK: - Status

    func testStatusPassesThroughIdenticallyOnBothBridges() async throws {
        // One status value, handed to both sides: FleetStatus carries a
        // construction timestamp, so separately built copies would differ.
        let status = FleetStatus(running: true, records: makeStatus(["kinhin-vm-1"]).records)
        let (real, _) = makeReal(status)
        let fake = FakeFleetIntentBridge(status)

        let realStatus = try await real.status()
        let fakeStatus = try await fake.status()

        XCTAssertEqual(fakeStatus, realStatus, "the intents read the same fleet either way")
        XCTAssertEqual(fakeStatus.records.map(\.id), ["kinhin-vm-1"])
    }

    // MARK: - Commands

    func testStartAndStopLeaveTheSameRunningStateOnBothBridges() async throws {
        let (real, backend) = makeReal()
        try await real.startFleet()
        let realRunning = try await real.status()
        try await real.stopFleet()
        let realStopped = try await real.status()

        let fake = FakeFleetIntentBridge(FleetStatus())
        fake.appliesStartStop = true
        try await fake.startFleet()
        let fakeRunning = try await fake.status()
        try await fake.stopFleet()
        let fakeStopped = try await fake.status()

        XCTAssertTrue(
            backend.calls.contains("start"),
            "the real bridge routes startFleet through the controller onto the backend: \(backend.calls)")
        XCTAssertTrue(backend.calls.contains("stop"))
        XCTAssertEqual(realRunning.running, true, "a started fleet reads running")
        XCTAssertEqual(fakeRunning.running, realRunning.running, "start means running on both bridges")
        XCTAssertEqual(realStopped.running, false)
        XCTAssertEqual(fakeStopped.running, realStopped.running, "stop means stopped on both bridges")
    }

    func testSetPausedLeavesTheSamePausedStateOnBothBridges() async throws {
        let (real, backend) = makeReal(FleetStatus(running: true))
        try await real.setPaused(true)
        let realStatus = try await real.status()

        let fake = FakeFleetIntentBridge(FleetStatus(running: true))
        try await fake.setPaused(true)
        let fakeStatus = try await fake.status()

        XCTAssertTrue(
            backend.calls.contains("setPaused(true)"),
            "the real bridge routes the pause onto the backend: \(backend.calls)")
        XCTAssertTrue(fake.setPausedCalls == [true], "the fake records what the backend received")
        XCTAssertEqual(realStatus.paused, true, "a paused fleet reads paused")
        XCTAssertEqual(fakeStatus.paused, realStatus.paused, "paused means paused on both bridges")
    }

    func testDeletingARecordLeavesTheSameRecordsOnBothBridges() async throws {
        let status = makeStatus(["kinhin-vm-1", "kinhin-vm-2"])
        let (real, backend) = makeReal(status)
        try await real.deleteVM(id: "kinhin-vm-1")
        let realStatus = try await real.status()

        let fake = FakeFleetIntentBridge(status)
        fake.appliesDelete = true
        try await fake.deleteVM(id: "kinhin-vm-1")
        let fakeStatus = try await fake.status()

        XCTAssertTrue(
            backend.calls.contains("deleteVM(kinhin-vm-1)"),
            "the real bridge routes the delete onto the backend: \(backend.calls)")
        XCTAssertEqual(fake.deleteCalls, ["kinhin-vm-1"], "the fake records the same call")
        XCTAssertEqual(
            realStatus.records.map(\.id), ["kinhin-vm-2"], "the backend dropped the deleted record")
        XCTAssertEqual(
            fakeStatus.records.map(\.id), realStatus.records.map(\.id),
            "the intents read the same fleet after a delete, whichever bridge answered")
    }

    // MARK: - Errors

    func testDeletingAnUnknownVMThrowsTheSameErrorOnBothBridges() async throws {
        let status = makeStatus(["kinhin-vm-1"])
        let (real, _) = makeReal(status)
        let realError = await firstError { try await real.deleteVM(id: "kinhin-ghost") }

        let fake = FakeFleetIntentBridge(status)
        let fakeError = await firstError { try await fake.deleteVM(id: "kinhin-ghost") }

        XCTAssertEqual(
            unknownVMID(fakeError), "kinhin-ghost",
            "the fake refuses an id the real chain's backend refuses")
        XCTAssertEqual(
            unknownVMID(realError), "kinhin-ghost",
            "the real bridge rethrows the backend's rejection")
        let fakeAfter = try await fake.status()
        XCTAssertEqual(
            fakeAfter.records.map(\.id), ["kinhin-vm-1"],
            "a rejected delete drops nothing")
    }

    func testTheSameErrorsSurfaceOnBothBridges() async throws {
        // No controller installed: the production bridge refuses with
        // fleetNotSetUp — exactly what a test scripts the fake to answer.
        let bare = AppFleetIntentBridge()
        let realNotSetUp = await firstError { _ = try await bare.status() }
        let fakeNotSetUp = await firstError {
            let fake = FakeFleetIntentBridge(FleetStatus())
            fake.error = EngineError.fleetNotSetUp
            _ = try await fake.status()
        }
        XCTAssertEqual(
            realNotSetUp as? EngineError, EngineError.fleetNotSetUp,
            "intents fail in Shortcuts before the app has a backend")
        XCTAssertEqual(
            fakeNotSetUp as? EngineError, realNotSetUp as? EngineError,
            "the fake must be scriptable with the identical refusal")

        // A backend command failure reaches Shortcuts as the backend's own
        // error on both sides.
        let (real, backend) = makeReal()
        backend.commandError = RPCError.timeout
        let realFailure = await firstError { try await real.startFleet() }
        let fakeFailure = await firstError {
            let fake = FakeFleetIntentBridge(FleetStatus())
            fake.error = RPCError.timeout
            try await fake.startFleet()
        }
        XCTAssertNotNil(realFailure, "the controller rethrows the backend's failure")
        XCTAssertNotNil(fakeFailure, "the fake throws its scripted failure")
        XCTAssertEqual(
            "\(fakeFailure!)", "\(realFailure!)",
            "the same wire error reads the same to the intent, whichever bridge surfaced it")
    }
}
