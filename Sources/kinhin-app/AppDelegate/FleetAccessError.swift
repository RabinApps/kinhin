import Foundation

/// Failures reaching the fleet from the app (menu actions, App Intents).
enum FleetAccessError: LocalizedError {
    /// Neither an in-process engine nor a daemon is available.
    case notSetUp

    var errorDescription: String? {
        switch self {
        case .notSetUp: return "kinhin isn't set up yet. Open kinhin to finish setup."
        }
    }
}
