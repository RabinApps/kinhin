import Foundation

/// Errors the fleet engine (or its app-side entry points) raise. Public
/// because `kinhin-app`'s fleet actions throw and alert on it directly.
public enum EngineError: LocalizedError, Sendable {
    case registrationFailed(vm: String, stderr: String)
    /// An account couldn't be attached (no instance URL, failed verification).
    case accountUnverified(String)
    /// The app's fleet entry points (menu actions, App Intents) ran before
    /// any backend was reachable — no in-process engine and no daemon.
    case fleetNotSetUp
    /// A start/stop was requested while another one is still running.
    case fleetBusy
    /// A runner id that isn't in the forge's id format (the engine only
    /// passes ids that came from the same forge's `runners()`).
    case invalidRunnerID(forge: ForgeID, id: String)
    /// A VM id that isn't one of kinhin's own (`kinhin-<ts>-<hex>`) or isn't
    /// in the store; deleting it would touch foreign runners or VMs.
    case unknownVM(String)
    /// A pipeline job id that isn't in the VM's current pipeline.
    case unknownPipelineJob(String)

    public var errorDescription: String? {
        switch self {
        case .registrationFailed(let vm, let stderr):
            return "runner registration failed on \(vm): \(stderr.prefix(300))"
        case .accountUnverified(let reason):
            return reason
        case .fleetNotSetUp:
            return "kinhin isn't set up yet. Open kinhin to finish setup."
        case .fleetBusy:
            return "The fleet is already starting or stopping. Try again in a moment."
        case .invalidRunnerID(let forge, let id):
            return "'\(id)' is not a \(forge.displayName) runner id"
        case .unknownVM(let id):
            return "'\(id)' is not a VM managed by kinhin"
        case .unknownPipelineJob(let id):
            return "'\(id)' is not a job of this VM's pipeline"
        }
    }
}
