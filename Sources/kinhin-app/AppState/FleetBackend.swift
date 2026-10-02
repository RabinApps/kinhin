import Foundation
import KinhinKit

/// A fleet start or stop, from any entry point (menu, Fleet tab, App Intent).
enum FleetAction: Sendable {
    case start
    case stop
}

/// What `FleetController` needs from whoever runs the fleet. `FleetBackend`
/// is the production conformance; tests substitute a fake with no engine or
/// daemon behind it.
protocol FleetServing: Sendable {
    func status() async throws -> FleetStatus
    func start() async throws
    func stop() async throws
    func setPaused(_ paused: Bool) async throws
    func deleteVM(id: String) async throws
    /// The live pipeline (jobs and steps) a VM is running; nil when it runs none.
    func pipelineDetail(vmID: String) async throws -> PipelineDetail?
    /// Hand a token already saved in the Keychain to the fleet.
    func rotate(_ target: CredentialRotation.Target, token: String) async throws
    /// A short name for log lines.
    var logName: String { get }
}

/// Whoever runs the fleet for this app: an engine in this process, or the
/// background daemon over RPC (off the main thread). Every fleet action goes
/// through here, so callers never branch on which one is live.
enum FleetBackend: Sendable {
    case inProcess(FleetEngine)
    case daemon(RPCClient)

    /// The in-process engine, when this app runs the fleet itself.
    var engine: FleetEngine? {
        if case .inProcess(let engine) = self { return engine }
        return nil
    }

    func status() async throws -> FleetStatus {
        switch self {
        case .inProcess(let engine): return await engine.status()
        case .daemon(let client): return try await client.perform { try $0.status() }
        }
    }

    func start() async throws {
        switch self {
        case .inProcess(let engine): await engine.start()
        case .daemon(let client): try await client.perform { try $0.command(.start) }
        }
    }

    func stop() async throws {
        switch self {
        case .inProcess(let engine): await engine.stop()
        case .daemon(let client): try await client.perform { try $0.command(.stop) }
        }
    }

    func setPaused(_ paused: Bool) async throws {
        switch self {
        case .inProcess(let engine): await engine.setPaused(paused)
        case .daemon(let client): try await client.perform { try $0.command(paused ? .pause : .resume) }
        }
    }

    func deleteVM(id: String) async throws {
        switch self {
        case .inProcess(let engine):
            try await engine.deleteVM(id: id)
        case .daemon(let client):
            let payload = try JSONEncoder().encode(Daemon.VMDeleteRequest(id: id))
            try await client.perform { try $0.command(.deleteVM, payload: payload) }
        }
    }

    func pipelineDetail(vmID: String) async throws -> PipelineDetail? {
        switch self {
        case .inProcess(let engine): return try await engine.pipelineDetail(vmID: vmID)
        case .daemon(let client): return try await client.perform { try $0.pipelineDetail(vmID: vmID) }
        }
    }

    func rotate(_ target: CredentialRotation.Target, token: String) async throws {
        switch self {
        case .inProcess(let engine): await CredentialRotation.apply(target, token: token, to: engine)
        case .daemon(let client):
            try await client.perform { try CredentialRotation.notify(target, token: token, daemon: $0) }
        }
    }

    var logName: String {
        switch self {
        case .inProcess: return "in-process engine"
        case .daemon: return "daemon"
        }
    }
}

extension FleetBackend: FleetServing {}
