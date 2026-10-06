import Foundation

/// Failures while preparing a runner image, for every runtime (Tart VM,
/// Docker, Apple container).
public enum ImageError: LocalizedError {
    /// Tart VM image provisioning failed.
    case provisioningFailed(String)
    /// Linux container image (Docker or Apple container) provisioning failed.
    case containerProvisioningFailed(String)
    /// Installing the host runner agent (host runtime) failed.
    case hostAgentInstallFailed(String)
    case noCredentials(String)
    case provisionScriptUnreadable(path: String, reason: String)
    /// A runner release feed answered but its payload was unusable (undecodable
    /// JSON, malformed tag). Network failures do not get here — the fetch itself
    /// degrades to the pinned version.
    case malformedVersionFeed(feed: String, reason: String)
    /// A rebuild was asked for a runtime whose config section is missing.
    case notConfigured(section: String)
    /// `--image NAME` named neither `image:` nor an `images:` entry.
    case unknownImage(String)
    /// An image operation needs a runtime (tart, container, docker) whose
    /// binary or service is not there. The message is the whole remedy.
    case runtimeUnavailable(String)

    public var errorDescription: String? {
        switch self {
        case .provisioningFailed(let why): return "image provisioning failed: \(why)"
        case .containerProvisioningFailed(let why): return "container image provisioning failed: \(why)"
        case .hostAgentInstallFailed(let why): return "host runner agent install failed: \(why)"
        case .noCredentials(let why): return "no platform credentials: \(why)"
        case .provisionScriptUnreadable(let path, let why): return "user provision script '\(path)': \(why)"
        case .malformedVersionFeed(let feed, let why):
            return "runner release feed '\(feed)' returned an unusable payload: \(why)"
        case .notConfigured(let section):
            return "no \(section).image is set — add a \(section): section first"
        case .unknownImage(let name):
            return "no image named '\(name)': it must be the image: value or an images: entry in the config"
        case .runtimeUnavailable(let why):
            return why
        }
    }
}
