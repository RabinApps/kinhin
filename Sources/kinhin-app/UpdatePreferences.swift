import Foundation

/// App-side update policy. The appcast URL and the check interval live in the
/// app's Info.plist (`SUFeedURL`, `SUScheduledCheckInterval`); this holds the
/// one override that is read at runtime.
enum UpdatePreferences {
    /// Points the updater at another appcast, for forks and local testing, via
    /// the KINHIN_UPDATE_FEED environment variable. The feed only supplies
    /// candidates: Sparkle still refuses any archive that is not signed with the
    /// EdDSA key in this build's `SUPublicEDKey`, so a redirected feed cannot
    /// install code this build's key did not sign.
    static func feedOverride(fromEnvironment env: [String: String]) -> String? {
        guard let feed = env["KINHIN_UPDATE_FEED"]?.trimmingCharacters(in: .whitespaces), !feed.isEmpty else {
            return nil
        }
        return feed
    }
}
