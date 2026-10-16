import Foundation

/// Errors the fleet engine (or its app-side entry points) raise. Public
/// because `kinhin-app`'s fleet actions throw and alert on it directly.
public enum EngineError: LocalizedError, Sendable {
    case registrationFailed(vm: String, stderr: String)
    /// An account couldn't be attached (no instance URL, failed verification).
    case accountUnverified(String)
    /// The requested forge is attached but has no queue implementation.
    case forgeNotFound(ForgeID)
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
    /// The logged action runs against a forge whose client has no queue
    /// override (only GitHub supports requeue/skip today).
    case queueOperationUnavailable
    /// A pipeline job id that isn't in the VM's current pipeline.
    case unknownPipelineJob(String)
    /// A scale-set forge method was called that the fleet does not support yet.
    case scaleSetRegistrationUnsupported
    /// A scale-set session or statistics read reached an unrecoverable state.
    case scaleSetUnreachable(account: String, reason: String)
    /// A healing event id that is not in the journal.
    case unknownHealingEvent(String)
    /// A healing event that cannot be approved or dismissed in its state.
    case healingEventNotPending(id: String, outcome: String)
    /// A healing fix ran and did not work.
    case healingFailed(String)
    /// The healing agent is stopped with the fleet; nothing can be approved until it starts.
    case healingStopped

    public var errorDescription: String? {
        switch self {
        case .forgeNotFound(let forge): return "no queue implementation for \(forge.displayName)"
        case .queueOperationUnavailable:
            return "the logged forge does not support requeue or skip"
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
        case .scaleSetRegistrationUnsupported:
            return "GitHub scale-set registration is not supported in this build yet"
        case .scaleSetUnreachable(let account, let reason):
            return "GitHub scale-set account '\(account)' is unreachable: \(reason)"
        case .unknownHealingEvent(let id):
            return "'\(id)' is not a healing event — see `kinhin heal` for the open ones"
        case .healingEventNotPending(let id, let outcome):
            return "healing event \(id) is \(outcome), not waiting on you"
        case .healingFailed(let reason):
            return reason
        case .healingStopped:
            return "the fleet is stopped; start it before approving a fix"
        }
    }
}

extension EngineError: Equatable {}
