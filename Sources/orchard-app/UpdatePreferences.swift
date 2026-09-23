import Foundation

/// App-side update policy: which repo to check, how often, and the last-check
/// stamp (UserDefaults, so the 24h throttle survives relaunches).
enum UpdatePreferences {
    /// The GitHub repo releases are published to. Fill in OWNER, or override
    /// for forks/local testing via the ORCHARD_UPDATE_REPO environment variable.
    static let repo: String = {
        repo(fromEnvironment: ProcessInfo.processInfo.environment)
    }()

    /// The repo-selection rule, injectable for tests: an env var containing
    /// "owner/name" wins; anything else (missing, empty, malformed) falls
    /// back to the default repo.
    static func repo(fromEnvironment env: [String: String]) -> String {
        if let env = env["ORCHARD_UPDATE_REPO"], env.contains("/") {
            return env
        }
        return "OWNER/orchard"
    }

    /// Automatic checks run at most once per day; the menu item always checks on demand.
    static let interval: TimeInterval = 24 * 60 * 60

    static var lastCheck: Date {
        get { lastCheck(in: .standard) }
        set { setLastCheck(newValue, in: .standard) }
    }

    /// Injectable accessors so tests can exercise the persistence round-trip
    /// against a scratch defaults suite instead of the app's real defaults.
    static func lastCheck(in defaults: UserDefaults) -> Date {
        defaults.object(forKey: "orchard.lastUpdateCheck") as? Date ?? .distantPast
    }

    static func setLastCheck(_ date: Date, in defaults: UserDefaults) {
        defaults.set(date, forKey: "orchard.lastUpdateCheck")
    }
}
