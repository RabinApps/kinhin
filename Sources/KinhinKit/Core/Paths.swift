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

    /// Writes `data` to `url` so the file is never readable by anyone but the
    /// owner, not even for an instant: it goes to a sibling temp file created
    /// 0600 (`O_EXCL`, so no planted file or symlink is followed) and is then
    /// renamed over `url`. A plain `write(atomically:)` creates the file with
    /// the default umask mode and a chmod afterwards leaves a window.
    public static func writePrivateFile(_ data: Data, to url: URL) throws {
        let temp = url.deletingLastPathComponent()
            .appendingPathComponent(".\(url.lastPathComponent).\(UUID().uuidString).tmp")
        let fd = open(temp.path, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        do {
            defer { close(fd) }
            // Exactly 0600 whatever the process umask is.
            guard fchmod(fd, 0o600) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
            var offset = 0
            while offset < data.count {
                let written = data.withUnsafeBytes { buffer in
                    write(fd, buffer.baseAddress.map { $0 + offset }, buffer.count - offset)
                }
                if written < 0 {
                    if errno == EINTR { continue }
                    throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
                }
                offset += written
            }
        } catch {
            // The temp file exists but is unusable; nothing else can have opened it.
            bestEffort("paths", "removing \(temp.lastPathComponent)") { try FileManager.default.removeItem(at: temp) }
            throw error
        }
        guard rename(temp.path, url.path) == 0 else {
            let code = POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            bestEffort("paths", "removing \(temp.lastPathComponent)") { try FileManager.default.removeItem(at: temp) }
            throw code
        }
    }

    /// The user's `~/Library/<name>` directory. `FileManager` returns it for
    /// every user domain; the home-relative path is only a defensive fallback.
    static func userLibrarySubdirectory(_ directory: FileManager.SearchPathDirectory, fallback: String) -> URL {
        FileManager.default.urls(for: directory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(fallback, isDirectory: true)
    }

    /// `~/Library/Application Support/Kinhin`
    static var appSupport: URL { cachedAppSupport }

    /// Resolved once: `FileManager.urls(for:in:)` is not free and this path is read on every config/state/log access.
    private static let cachedAppSupport: URL = {
        // `KINHIN_SUPPORT_DIR` relocates every support file (config, state, logs, daemon socket and lock) so the
        // end-to-end suite can run a real daemon without touching the user's own install. Keep it short: the daemon
        // socket lives inside and a unix socket path is limited to about 100 bytes.
        if let override = ProcessInfo.processInfo.environment["KINHIN_SUPPORT_DIR"], !override.isEmpty {
            return URL(fileURLWithPath: override, isDirectory: true)
        }
        return userLibrarySubdirectory(.applicationSupportDirectory, fallback: "Library/Application Support")
            .appendingPathComponent("Kinhin", isDirectory: true)
    }()

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
        // the first write into it fails with the real error. The private ones
        // are 0700 (created that way, or tightened if an older build made them
        // with the default umask); the toolchain cache is mounted into guests,
        // so it keeps default permissions.
        for directory in [appSupport, logsDirectory, stateDirectory] {
            bestEffort("paths", "securing \(directory.path)") {
                try createPrivateDirectory(directory)
                try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
            }
        }
        bestEffort("paths", "creating \(toolchainCache.path)") {
            try FileManager.default.createDirectory(at: toolchainCache, withIntermediateDirectories: true)
        }
        restrictExistingFiles()
    }

    /// Tightens files earlier builds created world-readable: the config and its
    /// backup, and the live and rotated logs.
    private static func restrictExistingFiles() {
        let fm = FileManager.default
        var files = [config, config.appendingPathExtension("bak")]
        // A missing logs directory just means there is nothing to tighten.
        let logs = (try? fm.contentsOfDirectory(at: logsDirectory, includingPropertiesForKeys: nil)) ?? []
        files += logs.filter { $0.lastPathComponent.hasPrefix("kinhin.log") }
        for file in files where fm.fileExists(atPath: file.path) {
            bestEffort("paths", "restricting \(file.lastPathComponent)") { try restrictToOwner(file) }
        }
    }

    /// Fixed directories searched before anything derived from `PATH`, so a
    /// writable directory a job or a stray shell profile put early on `PATH`
    /// cannot shadow `tart`, `docker`, `git` and friends.
    static let trustedBinaryDirectories = [
        "/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin", "/usr/sbin", "/sbin",
    ]

    /// Well-known locations a tool's own installer uses that `PATH` can miss
    /// (Docker Desktop keeps its CLI in `~/.docker/bin`), consulted only
    /// after the trusted directories and `PATH`. The list lives here, not in
    /// each caller, so every probe — engine health, setup checklist, doctor,
    /// app, image inventory, usage stats — agrees on which binary exists and
    /// on which one wins when a choice is possible.
    static let extraCandidateDirectories: [String: [String]] = [
        "docker": [NSHomeDirectory() + "/.docker/bin"]
    ]

    /// Locate a binary: explicit override, then the fixed trusted directories,
    /// then `PATH`, then the tool's well-known installer locations. An
    /// override is authoritative: a configured path that is not an executable
    /// is a misconfiguration, so it reports missing instead of silently
    /// probing elsewhere behind the user's back.
    public static func findExecutable(
        named name: String, override: String? = nil, extraDirectories: [String]? = nil
    ) -> String? {
        if let override, !override.isEmpty {
            return FileManager.default.isExecutableFile(atPath: override) ? override : nil
        }
        for dir in trustedBinaryDirectories {
            let candidate = "\(dir)/\(name)"
            if FileManager.default.isExecutableFile(atPath: candidate) { return candidate }
        }
        // PATH entries may be absolute (the common case) or relative: only
        // prefix a slash for relative ones, or the resolved path doubles the
        // leading slash ("//usr/local/bin/x").
        if let pathVar = ProcessInfo.processInfo.environment["PATH"] {
            for dir in pathVar.split(separator: ":") {
                let prefix = dir.hasPrefix("/") ? "" : "/"
                let candidate = "\(prefix)\(dir)/\(name)"
                if FileManager.default.isExecutableFile(atPath: candidate) { return candidate }
            }
        }
        for dir in extraDirectories ?? extraCandidateDirectories[name] ?? [] {
            let candidate = "\(dir)/\(name)"
            if FileManager.default.isExecutableFile(atPath: candidate) { return candidate }
        }
        return nil
    }
}
