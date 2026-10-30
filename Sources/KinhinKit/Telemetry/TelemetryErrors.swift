import Foundation

/// The bounded vocabulary of `kinhin.errors`: what failed, never the error text (free text
/// is unbounded, and can carry secrets).
enum TelemetryErrorType: String, CaseIterable, Sendable {
    case cloneFailure = "clone_failure"
    case bootTimeout = "boot_timeout"
    case sshUnreachable = "ssh_unreachable"
    case registrationFailure = "registration_failure"
    case runnerNotRegistered = "runner_not_registered"
    case instanceLost = "instance_lost"
    case forgeAPIFailure = "forge_api_failure"
    case rateLimited = "rate_limited"
    case teardownFailure = "teardown_failure"
    case unknown

    /// The part of kinhin an error came from (the `component` attribute).
    enum Component: String, Sendable {
        case lifecycle, reconcile, forge, runtime, healing, usage
    }

    /// Classifies a failure by where it happened and what it is. The stage decides when the
    /// error itself is not specific (a tart failure while cloning is a clone failure).
    static func classify(_ error: Error, stage: Metric.Phase?) -> TelemetryErrorType {
        if let api = error as? ForgeAPIError {
            if case .http(_, let code, _) = api, code == 429 { return .rateLimited }
            return stage == .registration ? .registrationFailure : .forgeAPIFailure
        }
        if let engine = error as? EngineError, case .registrationFailed = engine { return .registrationFailure }
        if let github = error as? GitHubError, case .rateLimited = github { return .rateLimited }
        if error is GitHubError { return stage == .registration ? .registrationFailure : .forgeAPIFailure }
        let text = ((error as? LocalizedError)?.errorDescription ?? "\(error)").lowercased()
        if text.contains("rate limit") { return .rateLimited }
        switch stage {
        case .provision: return .cloneFailure
        case .bootReady:
            if text.contains("ssh") || text.contains("connection refused") || text.contains("unreachable") {
                return .sshUnreachable
            }
            return .bootTimeout
        case .registration: return .registrationFailure
        case .teardown: return .teardownFailure
        case .run: return .unknown
        case nil: return .unknown
        }
    }
}
