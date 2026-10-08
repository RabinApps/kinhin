import Foundation

/// Shared scale-set error taxonomy used by the listener, client, and forge
/// adapter so the engine can render actionable messages without parsing HTTP
/// bodies or private implementation details.
public enum ScaleSetError: LocalizedError, Sendable {
    case noSession(reason: String)
    case sessionRefreshFailed(reason: String)
    case adminTokenFailure(reason: String)
    case scaleSetIdFailure(reason: String)
    case statisticsUnavailable(reason: String)
    case messageServiceFailure(reason: String)
    case jitConfigFailure(reason: String)
    case registrationFailure(reason: String)

    public var errorDescription: String? {
        switch self {
        case .noSession(let reason):
            return "scale-set session is not active: \(reason)"
        case .sessionRefreshFailed(let reason):
            return "scale-set session refresh failed: \(reason)"
        case .adminTokenFailure(let reason):
            return "scale-set admin token unavailable: \(reason)"
        case .scaleSetIdFailure(let reason):
            return "scale-set id unavailable: \(reason)"
        case .statisticsUnavailable(let reason):
            return "scale-set statistics unavailable: \(reason)"
        case .messageServiceFailure(let reason):
            return "scale-set message service failed: \(reason)"
        case .jitConfigFailure(let reason):
            return "scale-set JIT config generation failed: \(reason)"
        case .registrationFailure(let reason):
            return "scale-set registration failed: \(reason)"
        }
    }
}
