import Foundation

/// Filesystem locations for kinhin's support files and binary discovery.
public enum Paths {
    /// Creates `url` (and missing parents) with the final directory readable
    /// only by the owner. Logs and fleet state hold VM ids, addresses and
    /// repository names that other local users have no business reading.
    static func createPrivateDirectory(_ url: URL) throws {
        try FileManager.default.createDirectory(
            at: url, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    }

    /// Restricts an existing file to its owner (0600).
    static func restrictToOwner(_ url: URL) throws {
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    /// The user's `~/Library/<name>` directory. `FileManager` returns it for
    /// every user domain; the home-relative path is only a defensive fallback.
    static func userLibrarySubdirectory(_ directory: FileManager.SearchPathDirectory, fallback: String) -> URL {
        FileManager.default.urls(for: directory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(fallback, isDirectory: true)
    }

    /// `~/Library/Application Support/Kinhin`
    static var appSupport: URL {
        userLibrarySubdirectory(.applicationSupportDirectory, fallback: "Library/Application Support")
            .appendingPathComponent("Kinhin", isDirectory: true)
    }

    /// Support directory used by the pre-rename build ("Orchard").
    static var legacyAppSupport: URL {
        userLibrarySubdirectory(.applicationSupportDirectory, fallback: "Library/Application Support")
            .appendingPathComponent("Orchard", isDirectory: true)
    }

    /// One-time migration from the pre-rename support directory: when the
    /// legacy `Application Support/Orchard` folder exists and the new one
    /// does not, move it (same-volume rename; config, logs, toolchain cache
    /// and state all carry over). Failures never block startup — the new
    /// directory is simply created empty on the next line.
    static func migrateLegacySupportDirectory(fileManager: FileManager = .default) {
        migrateLegacySupportDirectory(from: legacyAppSupport, to: appSupport, fileManager: fileManager)
    }

    /// Injectable core of the migration so tests can exercise it on temp dirs.
    static func migrateLegacySupportDirectory(from legacy: URL, to new: URL, fileManager: FileManager = .default) {
        guard fileManager.fileExists(atPath: legacy.path),
            !fileManager.fileExists(atPath: new.path)
        else { return }
        do {
            try fileManager.createDirectory(at: new.deletingLastPathComponent(), withIntermediateDirectories: true)
            try fileManager.moveItem(at: legacy, to: new)
            Log.info("paths", "migrated pre-rename support directory (Orchard → Kinhin)")
        } catch {
            Log.warn("paths", "could not migrate pre-rename support directory: \(error.localizedDescription)")
        }
    }

    public static var config: URL { appSupport.appendingPathComponent("config.yaml") }

    public static var logsDirectory: URL { appSupport.appendingPathComponent("logs", isDirectory: true) }

    /// Deliberately NOT the app's bundle id: tokens saved by earlier builds
    /// (bundle id `com.kinhin.runner`) must stay readable after the rename.
    static var keychainService: String { "com.kinhin.runner" }

    /// Shared toolchain download cache (mise, brew, npm, fvm, Go, Cargo…).
    /// Mounted read-write into scratch VMs at prepare time and — opt-in via
    /// `toolchains.share_cache` — into runner VMs. See `ToolchainCacheMount`.
    public static var toolchainCache: URL {
        appSupport.appendingPathComponent(ToolchainCacheMount.hostDirectoryName, isDirectory: true)
    }

    /// Directory where per-VM bootstrap scripts and state live.
    public static var stateDirectory: URL { appSupport.appendingPathComponent("state", isDirectory: true) }

    public static func ensureSupportDirectories() {
        migrateLegacySupportDirectory()
        // Best effort: a directory that cannot be created is logged here, and
        // the first write into it fails with the real error.
        for directory in [appSupport, logsDirectory, stateDirectory, toolchainCache] {
            bestEffort("paths", "creating \(directory.path)") {
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            }
        }
    }

    /// Locate a binary: explicit override, PATH, then Homebrew prefixes.
    public static func findExecutable(named name: String, override: String? = nil) -> String? {
        if let override, !override.isEmpty, FileManager.default.isExecutableFile(atPath: override) {
            return override
        }
        // Honor the user's PATH first. PATH entries may be absolute (the
        // common case) or relative — only prefix a slash for relative ones,
        // or the resolved path doubles the leading slash ("//usr/local/bin/x").
        if let pathVar = ProcessInfo.processInfo.environment["PATH"] {
            for dir in pathVar.split(separator: ":") {
                let prefix = dir.hasPrefix("/") ? "" : "/"
                let candidate = "\(prefix)\(dir)/\(name)"
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
