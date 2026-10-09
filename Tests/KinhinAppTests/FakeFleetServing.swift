import Foundation
import Synchronization

@testable import KinhinKit
@testable import kinhin_app

/// A `FleetServing` with no engine or daemon: scripted status, recorded
/// calls, and an optional gate that holds start/stop open so tests can
/// observe the pending state mid-command.
final class FakeFleetServing: FleetServing {
    private struct State {
        var status: FleetStatus
        var statusError: Error?
        var commandError: Error?
        var calls: [String] = []
        var gate: CheckedContinuation<Void, Never>?
        var gated = false
        var pipeline: PipelineDetail?
        var pipelineLog: PipelineLog?
        var requeueResult = true
        var skipResult = true
        var benchStatuses: [BenchmarkRunStatus] = []
        var benchStarted: [BenchmarkOptions] = []
        var benchCancelled: [String?] = []
    }

    private let state: Mutex<State>
    /// Whether `status()` also waits on the gate (a poll held mid-flight).
    private let statusGate = Mutex(false)
    var gatesStatus: Bool {
        get { statusGate.withLock { $0 } }
        set { statusGate.withLock { $0 = newValue } }
    }

    init(_ status: FleetStatus = FleetStatus()) {
        state = Mutex(State(status: status))
    }

    var logName: String { "fake" }
    var calls: [String] { state.withLock { $0.calls } }

    var status: FleetStatus {
        get { state.withLock { $0.status } }
        set { state.withLock { $0.status = newValue } }
    }
    var statusError: Error? {
        get { state.withLock { $0.statusError } }
        set { state.withLock { $0.statusError = newValue } }
    }
    var commandError: Error? {
        get { state.withLock { $0.commandError } }
        set { state.withLock { $0.commandError = newValue } }
    }
    /// While set, start/stop suspend until `releaseGate()`.
    var gated: Bool {
        get { state.withLock { $0.gated } }
        set { state.withLock { $0.gated = newValue } }
    }

    func releaseGate() {
        let continuation = state.withLock { state -> CheckedContinuation<Void, Never>? in
            state.gated = false
            defer { state.gate = nil }
            return state.gate
        }
        continuation?.resume()
    }

    private func record(_ call: String) throws {
        let error = state.withLock { state -> Error? in
            state.calls.append(call)
            return state.commandError
        }
        if let error { throw error }
    }

    private func waitForGate() async {
        guard state.withLock({ $0.gated }) else { return }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let resumeNow = state.withLock { state -> Bool in
                guard state.gated else { return true }
                state.gate = continuation
                return false
            }
            if resumeNow { continuation.resume() }
        }
    }

    /// The `includeUsage` flag of each `status(includeUsage:)` poll, in order.
    private let usageFlags = Mutex<[Bool]>([])
    var usageFlagsSeen: [Bool] { usageFlags.withLock { $0 } }

    func status(includeUsage: Bool) async throws -> FleetStatus {
        usageFlags.withLock { $0.append(includeUsage) }
        return try await status()
    }

    func status() async throws -> FleetStatus {
        state.withLock { $0.calls.append("status") }
        if gatesStatus { await waitForGate() }
        return try state.withLock { state in
            if let error = state.statusError { throw error }
            return state.status
        }
    }

    func start() async throws {
        try record("start")
        await waitForGate()
        state.withLock { $0.status.running = true }
    }

    func stop() async throws {
        try record("stop")
        await waitForGate()
        state.withLock { $0.status.running = false }
    }

    func setPaused(_ paused: Bool) async throws {
        try record("setPaused(\(paused))")
        state.withLock { $0.status.paused = paused }
    }

    func deleteVM(id: String) async throws {
        try record("deleteVM(\(id))")
        // The engine refuses an id it doesn't have (`EngineError.unknownVM`)
        // before touching anything; mirroring that keeps a caller missing its
        // own pre-check from passing against the fake and failing in production.
        let removed = state.withLock { state -> Bool in
            guard VMRecord.isValidID(id), state.status.records.contains(where: { $0.id == id }) else { return false }
            state.status.records.removeAll { $0.id == id }
            return true
        }
        guard removed else { throw EngineError.unknownVM(id) }
    }

    /// What `requeueQueuedJobs(for:)` answered (nil: no data).
    var requeueResult: Bool {
        get { state.withLock { $0.requeueResult } }
        set { state.withLock { $0.requeueResult = newValue } }
    }
    var skipResult: Bool {
        get { state.withLock { $0.skipResult } }
        set { state.withLock { $0.skipResult = newValue } }
    }

    func requeueQueuedJobs(for forge: ForgeID) async throws {
        try record("requeueQueuedJobs(\(forge.rawValue))")
        _ = try? await requeueResult
    }

    func skipQueuedJobs(for forge: ForgeID) async throws {
        try record("skipQueuedJobs(\(forge.rawValue))")
        _ = try? await skipResult
    }

    /// What `pipelineDetail` answers (nil: the VM runs no job).
    var pipeline: PipelineDetail? {
        get { state.withLock { $0.pipeline } }
        set { state.withLock { $0.pipeline = newValue } }
    }

    func pipelineDetail(vmID: String) async throws -> PipelineDetail? {
        try record("pipelineDetail(\(vmID))")
        return state.withLock { $0.pipeline }
    }

    /// What `pipelineLog` answers (nil: no output available).
    var pipelineLogResult: PipelineLog? {
        get { state.withLock { $0.pipelineLog } }
        set { state.withLock { $0.pipelineLog = newValue } }
    }

    func pipelineLog(vmID: String, jobID: String, stepIndex: Int?) async throws -> PipelineLog? {
        try record("pipelineLog(\(vmID),\(jobID),\(stepIndex.map(String.init) ?? "-"))")
        return state.withLock { $0.pipelineLog }
    }

    func rotate(_ target: CredentialRotation.Target, token: String) async throws {
        try record("rotate(\(target.accountName))")
    }

    // MARK: - Benchmarks

    /// What successive `benchStatus` calls answer; the last one repeats.
    var benchStatuses: [BenchmarkRunStatus] {
        get { state.withLock { $0.benchStatuses } }
        set { state.withLock { $0.benchStatuses = newValue } }
    }
    var benchStarted: [BenchmarkOptions] { state.withLock { $0.benchStarted } }
    var benchCancelled: [String?] { state.withLock { $0.benchCancelled } }

    func benchStart(_ options: BenchmarkOptions) async throws -> String {
        try record("benchStart")
        state.withLock { $0.benchStarted.append(options) }
        return "bench-fake"
    }

    func benchStatus(runID: String?) async throws -> BenchmarkRunStatus {
        try record("benchStatus(\(runID ?? "-"))")
        return try state.withLock { state in
            guard let first = state.benchStatuses.first else { throw BenchmarkError.unknownRun(runID ?? "(none)") }
            if state.benchStatuses.count > 1 { state.benchStatuses.removeFirst() }
            return first
        }
    }

    func benchCancel(runID: String?) async throws -> Bool {
        try record("benchCancel(\(runID ?? "-"))")
        // Like the registry: only a live run can be cancelled.
        return state.withLock { state in
            state.benchCancelled.append(runID)
            return state.benchStatuses.first?.state == .running
        }
    }
}
