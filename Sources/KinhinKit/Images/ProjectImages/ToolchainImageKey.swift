import CryptoKit
import Foundation

/// Identity of a derived per-project image: a stable hash of the resolved
/// toolchain set, the platform, the cache-share setting and the base image
/// it is cloned from. Repos that resolve to the same set (and cache setting)
/// share one image; the key also scopes the project's cache directory.
enum ToolchainImageKey {
    /// `p` + 8 hex characters, e.g. `p3a9f12c4`.
    static func make(
        toolchains: KinhinConfig.ToolchainsConfig, base: String, platform: ToolchainPlatform, shareCache: Bool = false
    ) -> String {
        let canonical = [
            "base=\(base)",
            "platform=\(platform)",
            "cache=\(shareCache)",
            "specs=\(normalized(toolchains.specs).joined(separator: ","))",
            "brew=\(normalized(toolchains.brew).joined(separator: ","))",
            "stacks=\(normalized(toolchains.stacks).joined(separator: ","))",
        ].joined(separator: "\n")
        let digest = SHA256.hash(data: Data(canonical.utf8))
        let hex = digest.map { String(format: "%02x", $0) }.joined()
        return "p" + hex.prefix(8)
    }

    /// The derived image name for a base image and key.
    static func imageName(base: String, key: String) -> String { "\(base)-\(key)" }

    /// Sorted, trimmed, lower-cased so `Node@22` and `node@22` hash alike.
    private static func normalized(_ entries: [String]?) -> [String] {
        (entries ?? []).map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }.sorted()
    }
}
