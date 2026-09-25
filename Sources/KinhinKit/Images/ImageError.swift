import Foundation

/// Failures while preparing a runner image, for every runtime (Tart VM,
/// Docker, Apple container).
public enum ImageError: LocalizedError {
    /// Tart VM image provisioning failed.
    case provisioningFailed(String)
    /// Linux container image (Docker or Apple container) provisioning failed.
    case containerProvisioningFailed(String)
    case noCredentials(String)
    case provisionScriptUnreadable(path: String, reason: String)

    public var errorDescription: String? {
        switch self {
        case .provisioningFailed(let why): return "image provisioning failed: \(why)"
        case .containerProvisioningFailed(let why): return "container image provisioning failed: \(why)"
        case .noCredentials(let why): return "no platform credentials: \(why)"
        case .provisionScriptUnreadable(let path, let why): return "user provision script '\(path)': \(why)"
        }
    }
}
