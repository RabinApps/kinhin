import Foundation

// Daemon — the LaunchAgent that keeps `kinhin daemon` running at login.
extension Daemon {
    public static func agentPlistPath() -> URL {
        Paths.userLibrarySubdirectory(.libraryDirectory, fallback: "Library")
            .appendingPathComponent("LaunchAgents/\(plistName)")
    }

    /// Escapes the five XML special characters for text inside a plist
    /// `<string>`: a path containing `&` or `<` would otherwise break the file.
    static func xmlEscaped(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&apos;")
    }

    /// Write the LaunchAgent plist pointing at the given kinhin binary.
    public static func installAgent(binaryPath: String) throws {
        let logs = Paths.logsDirectory
        let plist = """
            <?xml version="1.0" encoding="UTF-8"?>
            <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
            <plist version="1.0">
            <dict>
                <key>Label</key>
                <string>com.kinhin.daemon</string>
                <key>ProgramArguments</key>
                <array>
                    <string>\(xmlEscaped(binaryPath))</string>
                    <string>daemon</string>
                </array>
                <key>RunAtLoad</key>
                <true/>
                <key>KeepAlive</key>
                <true/>
                <key>StandardOutPath</key>
                <string>\(xmlEscaped(logs.appendingPathComponent("daemon.out.log").path))</string>
                <key>StandardErrorPath</key>
                <string>\(xmlEscaped(logs.appendingPathComponent("daemon.err.log").path))</string>
            </dict>
            </plist>
            """
        let url = agentPlistPath()
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try plist.write(to: url, atomically: true, encoding: .utf8)
        Log.info("daemon", "launchagent written to \(url.path)")
    }

    public static func uninstallAgent() throws {
        let fm = FileManager.default
        // Pre-rename builds installed under the com.kinhin.daemon label.
        let legacy = Paths.userLibrarySubdirectory(.libraryDirectory, fallback: "Library")
            .appendingPathComponent("LaunchAgents/\(plistName)")
        for url in [agentPlistPath(), legacy] where fm.fileExists(atPath: url.path) {
            try fm.removeItem(at: url)
        }
    }

    /// Stops the LaunchAgent daemon and removes its plist — both labels.
    /// Shared by `kinhin daemon uninstall` and the reset's daemon scope.
    /// Tolerant of an agent that is not loaded or already gone (that is the
    /// normal case for a reset); the plist removal is the part that matters
    /// and may throw.
    public static func stopAndUninstall(shell: ShellRunning = Shell()) async throws {
        let plist = agentPlistPath()
        // Modern bootout first; the legacy unload verb is the fallback for
        // older macOS wording. Either is enough to stop a loaded agent, and
        // both no-op on an unloaded one.
        let uid = getuid()
        await bestEffortAsync("daemon", "launchctl bootout") {
            _ = try await shell.run(["launchctl", "bootout", "gui/\(uid)", plist.path], cwd: nil, timeout: 30)
        }
        do {
            _ = try await shell.run(["launchctl", "unload", plist.path], cwd: nil, timeout: 30)
        } catch {
            // Unloading an agent that isn't loaded, or a context where
            // launchctl isn't available (e.g. non-interactive shells), is
            // fine: removing the plist is what matters.
            let msg = error.localizedDescription
            if !(msg.contains("doesn't exist") || msg.contains("No such file")) {
                Log.warn("daemon", "could not run launchctl unload (\(msg)); removing the plist anyway")
            }
        }
        try uninstallAgent()
    }
}
