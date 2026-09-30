import Foundation

// Daemon — the LaunchAgent that keeps `kinhin daemon` running at login.
extension Daemon {
    public static func agentPlistPath() -> URL {
        Paths.userLibrarySubdirectory(.libraryDirectory, fallback: "Library")
            .appendingPathComponent("LaunchAgents/\(plistName)")
    }

    /// Write the LaunchAgent plist pointing at the given kinhin binary.
    public static func installAgent(binaryPath: String) throws {
        let plist = """
            <?xml version="1.0" encoding="UTF-8"?>
            <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
            <plist version="1.0">
            <dict>
                <key>Label</key>
                <string>com.kinhin.daemon</string>
                <key>ProgramArguments</key>
                <array>
                    <string>\(binaryPath)</string>
                    <string>daemon</string>
                </array>
                <key>RunAtLoad</key>
                <true/>
                <key>KeepAlive</key>
                <true/>
                <key>StandardOutPath</key>
                <string>\(Paths.logsDirectory.appendingPathComponent("daemon.out.log").path)</string>
                <key>StandardErrorPath</key>
                <string>\(Paths.logsDirectory.appendingPathComponent("daemon.err.log").path)</string>
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
        // Pre-rename builds installed under the com.orchard.daemon label.
        let legacy = Paths.userLibrarySubdirectory(.libraryDirectory, fallback: "Library")
            .appendingPathComponent("LaunchAgents/com.orchard.daemon.plist")
        for url in [agentPlistPath(), legacy] where fm.fileExists(atPath: url.path) {
            try fm.removeItem(at: url)
        }
    }
}
