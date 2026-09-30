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

    public var errorDescription: String? {
        switch self {
        case .registrationFailed(let vm, let stderr):
            return "runner registration failed on \(vm): \(stderr.prefix(300))"
        case .accountUnverified(let reason):
            return reason
        case .fleetNotSetUp:
            return "kinhin isn't set up yet. Open kinhin to finish setup."
        }
    }
}
