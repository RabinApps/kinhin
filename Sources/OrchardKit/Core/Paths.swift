import Foundation

/// Filesystem locations for Orchard's support files and binary discovery.
public enum Paths {
    /// `~/Library/Application Support/Orchard`
    public static var appSupport: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return base.appendingPathComponent("Orchard", isDirectory: true)
    }

    public static var config: URL { appSupport.appendingPathComponent("config.yaml") }

    public static var logsDirectory: URL { appSupport.appendingPathComponent("logs", isDirectory: true) }

    public static var keychainService: String { "com.orchard.runner" }

    /// Shared toolchain download cache (mise, brew, npm, fvm, Go, Cargo…).
    /// Mounted read-write into scratch VMs at prepare time and — opt-in via
    /// `toolchains.share_cache` — into runner VMs. See `ToolchainCacheMount`.
    public static var toolchainCache: URL { appSupport.appendingPathComponent(ToolchainCacheMount.hostDirectoryName, isDirectory: true) }

    /// Directory where per-VM bootstrap scripts and state live.
    public static var stateDirectory: URL { appSupport.appendingPathComponent("state", isDirectory: true) }

    public static func ensureSupportDirectories() {
        try? FileManager.default.createDirectory(at: appSupport, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: logsDirectory, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: stateDirectory, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: toolchainCache, withIntermediateDirectories: true)
    }

    /// Locate a binary: explicit override, PATH, then Homebrew prefixes.
    public static func findExecutable(named name: String, override: String? = nil) -> String? {
        if let override, !override.isEmpty, FileManager.default.isExecutableFile(atPath: override) {
            return override
        }
        // Honor the user's PATH first.
        if let pathVar = ProcessInfo.processInfo.environment["PATH"] {
            for dir in pathVar.split(separator: ":") {
                let candidate = "/\(dir)/\(name)"
                if FileManager.default.isExecutableFile(atPath: candidate) {
                    return candidate
                }
            }
        }
        // Common Homebrew locations on Apple Silicon and Intel.
        let brewCandidates = [
            "/opt/homebrew/bin/\(name)",
            "/usr/local/bin/\(name)",
        ]
        return brewCandidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }
}
