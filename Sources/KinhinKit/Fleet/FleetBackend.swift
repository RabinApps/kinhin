import Foundation

/// What a fleet client (the app's `FleetController`, the CLI's stop/pause/resume,
/// the MCP control tools) needs from whoever runs the fleet. `FleetBackend` is
/// the production conformance; tests substitute a fake with no engine or
/// daemon behind it.
public protocol FleetServing: Sendable {
    func status() async throws -> FleetStatus
    /// `includeUsage: false` skips the CPU/RAM sampling for a poll nobody is
    /// looking at. Conformers that predate the option get the full status.
    func status(includeUsage: Bool) async throws -> FleetStatus
    func start() async throws
    func stop() async throws
    func setPaused(_ paused: Bool) async throws
    func deleteVM(id: String) async throws
    /// The live pipeline (jobs and steps) a VM is running; nil when it runs none.
    func pipelineDetail(vmID: String) async throws -> PipelineDetail?
    /// The output of a step (or job, with no `stepIndex`) of a VM's pipeline.
    func pipelineLog(vmID: String, jobID: String, stepIndex: Int?) async throws -> PipelineLog?
    /// Hand a token already saved in the Keychain to the fleet.
    func rotate(_ target: CredentialRotation.Target, token: String) async throws
    /// Requeue the queued jobs for one forge (org scope covers every repo).
    func requeueQueuedJobs(for forge: ForgeID) async throws
    /// Mark the queued jobs for one forge as skipped.
    func skipQueuedJobs(for forge: ForgeID) async throws
    /// Start a benchmark run (it pauses the fleet while it measures); returns the run id.
    func benchStart(_ options: BenchmarkOptions) async throws -> String
    /// Progress, partial results and the finished report of a run (the latest when nil).
    func benchStatus(runID: String?) async throws -> BenchmarkRunStatus
    /// Cancel a running benchmark; false when none was running.
    func benchCancel(runID: String?) async throws -> Bool
    /// The healing agent's policy and journal.
    func healingStatus() async throws -> HealingSnapshot
    /// Carry out a healing fix that waits for approval (it runs in the background).
    func approveHealing(id: String) async throws
    /// Close a pending or surfaced healing event.
    func dismissHealing(id: String) async throws
    /// A short name for log lines.
    var logName: String { get }
}

extension FleetServing {
    public func status(includeUsage: Bool) async throws -> FleetStatus { try await status() }

    public func benchStart(_ options: BenchmarkOptions) async throws -> String {
        throw BenchmarkError.unsupported("\(logName) cannot run benchmarks")
    }

    public func benchStatus(runID: String?) async throws -> BenchmarkRunStatus {
        throw BenchmarkError.unsupported("\(logName) cannot run benchmarks")
    }

    public func benchCancel(runID: String?) async throws -> Bool {
        throw BenchmarkError.unsupported("\(logName) cannot run benchmarks")
    }

    /// From the status: every conformer that reports a status reports healing.
    public func healingStatus() async throws -> HealingSnapshot {
        guard let healing = try await status(includeUsage: false).healing else {
            throw EngineError.healingFailed("\(logName) does not report healing")
        }
        return healing
    }

    public func approveHealing(id: String) async throws {
        throw EngineError.healingFailed("\(logName) cannot approve healing fixes")
    }

    public func dismissHealing(id: String) async throws {
        throw EngineError.healingFailed("\(logName) cannot dismiss healing events")
    }
}

/// Whoever runs the fleet for this app: an engine in this process, or the
/// background daemon over RPC (off the main thread). Every fleet action goes
/// through here, so callers never branch on which one is live.
public enum FleetBackend: Sendable {
    case inProcess(FleetEngine)
    case daemon(RPCClient)

    /// The in-process engine, when this app runs the fleet itself.
    public var engine: FleetEngine? {
        if case .inProcess(let engine) = self { return engine }
        return nil
    }

    public func status() async throws -> FleetStatus {
        try await status(includeUsage: true)
    }

    public func status(includeUsage: Bool) async throws -> FleetStatus {
        switch self {
        case .inProcess(let engine): return await engine.status(includeUsage: includeUsage)
        case .daemon(let client): return try await client.perform { try $0.status(includeUsage: includeUsage) }
        }
    }

    public func start() async throws {
        switch self {
        case .inProcess(let engine): await engine.start()
        case .daemon(let client): try await client.perform { try $0.command(.start) }
        }
    }

    public func stop() async throws {
        switch self {
        case .inProcess(let engine): await engine.stop()
        case .daemon(let client): try await client.perform { try $0.command(.stop) }
        }
    }

    public func setPaused(_ paused: Bool) async throws {
        switch self {
        case .inProcess(let engine): await engine.setPaused(paused)
        case .daemon(let client): try await client.perform { try $0.command(paused ? .pause : .resume) }
        }
    }

    public func deleteVM(id: String) async throws {
        switch self {
        case .inProcess(let engine):
            try await engine.deleteVM(id: id)
        case .daemon(let client):
            let payload = try JSONEncoder().encode(Daemon.VMDeleteRequest(id: id))
            try await client.perform { try $0.command(.deleteVM, payload: payload) }
        }
    }

    public func pipelineDetail(vmID: String) async throws -> PipelineDetail? {
        switch self {
        case .inProcess(let engine): return try await engine.pipelineDetail(vmID: vmID)
        case .daemon(let client): return try await client.perform { try $0.pipelineDetail(vmID: vmID) }
        }
    }

    public func pipelineLog(vmID: String, jobID: String, stepIndex: Int?) async throws -> PipelineLog? {
        switch self {
        case .inProcess(let engine): return try await engine.pipelineLog(vmID: vmID, jobID: jobID, stepIndex: stepIndex)
        case .daemon(let client):
            return try await client.perform { try $0.pipelineLog(vmID: vmID, jobID: jobID, stepIndex: stepIndex) }
        }
    }

    public func requeueQueuedJobs(for forge: ForgeID) async throws {
        switch self {
        case .inProcess(let engine): try await engine.requeueQueuedJobs(for: forge)
        case .daemon(let client):
            let payload = try JSONEncoder().encode(Daemon.ForgeJobsRequest(forge: forge))
            try await client.perform { try $0.command(.requeueQueuedJobs, payload: payload) }
        }
    }

    public func skipQueuedJobs(for forge: ForgeID) async throws {
        switch self {
        case .inProcess(let engine): try await engine.skipQueuedJobs(for: forge)
        case .daemon(let client):
            let payload = try JSONEncoder().encode(Daemon.ForgeJobsRequest(forge: forge))
            try await client.perform { try $0.command(.skipQueuedJobs, payload: payload) }
        }
    }

    public func rotate(_ target: CredentialRotation.Target, token: String) async throws {
        switch self {
        case .inProcess(let engine): await CredentialRotation.apply(target, token: token, to: engine)
        case .daemon(let client):
            try await client.perform { try CredentialRotation.notify(target, token: token, daemon: $0) }
        }
    }

    public func benchStart(_ options: BenchmarkOptions) async throws -> String {
        switch self {
        case .inProcess(let engine):
            return try BenchmarkRegistry.shared.start(options: options, environment: engine.benchmarkEnvironment())
        case .daemon(let client): return try await client.perform { try $0.benchStart(options) }
        }
    }

    public func benchStatus(runID: String?) async throws -> BenchmarkRunStatus {
        switch self {
        case .inProcess:
            guard let status = BenchmarkRegistry.shared.status(runID: runID) else {
                throw BenchmarkError.unknownRun(runID ?? "(none started)")
            }
            return status
        case .daemon(let client): return try await client.perform { try $0.benchStatus(runID: runID) }
        }
    }

    public func benchCancel(runID: String?) async throws -> Bool {
        switch self {
        case .inProcess: return BenchmarkRegistry.shared.cancel(runID: runID)
        case .daemon(let client): return try await client.perform { try $0.benchCancel(runID: runID) }
        }
    }

    public func healingStatus() async throws -> HealingSnapshot {
        switch self {
        case .inProcess(let engine): return await engine.healingStatus()
        case .daemon(let client): return try await client.perform { try $0.healingStatus() }
        }
    }

    public func approveHealing(id: String) async throws {
        switch self {
        case .inProcess(let engine): try await engine.approveHealing(id: id)
        case .daemon(let client): try await client.perform { try $0.healingDecide(id: id, approve: true) }
        }
    }

    public func dismissHealing(id: String) async throws {
        switch self {
        case .inProcess(let engine): try await engine.dismissHealing(id: id)
        case .daemon(let client): try await client.perform { try $0.healingDecide(id: id, approve: false) }
        }
    }

    public var logName: String {
        switch self {
        case .inProcess: return "in-process engine"
        case .daemon: return "daemon"
        }
    }
}

// MARK: - Start or attach

extension FleetBackend {
    /// The backend for a running daemon, or nil when none answers. The ping
    /// runs off the caller's thread (it blocks on the socket).
    public static func attachToDaemon(client: RPCClient = RPCClient()) async -> FleetBackend? {
        let alive = await Task.detached { RPCClient.isDaemonAlive(socketURL: client.socketURL) }.value
        return alive ? .daemon(client) : nil
    }

    /// Attach to a running daemon when there is one; otherwise run an engine
    /// in this process. `makeEngine` is only called with no daemon, and may
    /// return nil when the config cannot run a fleet yet (setup incomplete).
    public static func startOrAttach(
        client: RPCClient = RPCClient(),
        makeEngine: () async throws -> FleetEngine?
    ) async throws -> FleetBackend? {
        if let daemon = await attachToDaemon(client: client) { return daemon }
        return try await makeEngine().map { .inProcess($0) }
    }
}

extension FleetBackend: FleetServing {}
