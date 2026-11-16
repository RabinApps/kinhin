import Darwin
import Foundation

// Daemon — the LaunchAgent that keeps `kinhin daemon` running at login.
extension Daemon {
    public static func agentPlistPath() -> URL {
        Paths.userLibrarySubdirectory(.libraryDirectory, fallback: "Library")
            .appendingPathComponent("LaunchAgents/\(plistName)")
    }

    /// Absolute: `Shell` runs argv[0] as a path, so a bare `launchctl` resolved
    /// against the working directory and `kinhin daemon install` always failed.
    static let launchctlPath = "/bin/launchctl"

    /// The binary a LaunchAgent should run: use the process image rather than
    /// argv[0], which may be a bare command found through PATH. Resolve
    /// symlinks so an installed command linking into the app is judged by its target.
    public static func currentExecutable() throws -> String {
        if let path = Bundle.main.executablePath, !path.isEmpty {
            return launchAgentBinary(argv0: path)
        }
        var capacity: UInt32 = 1024
        while true {
            var buffer = [CChar](repeating: 0, count: Int(capacity))
            var size = capacity
            let result = _NSGetExecutablePath(&buffer, &size)
            if result == 0 {
                let bytes = buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }
                let path = String(decoding: bytes, as: UTF8.self)
                guard !path.isEmpty else { throw DaemonError.executablePathUnavailable }
                return launchAgentBinary(argv0: path)
            }
            guard size > capacity else { throw DaemonError.executablePathUnavailable }
            capacity = size
        }
    }

    /// Absolute, standardized executable path with symlinks resolved.
    public static func launchAgentBinary(argv0: String) -> String {
        URL(fileURLWithPath: argv0).standardizedFileURL.resolvingSymlinksInPath().path
    }

    /// A SwiftPM debug build: never installed as a LaunchAgent (it carries
    /// development-only token handling, and the next `swift build` replaces it).
    public static func isDebugBuild(_ path: String) -> Bool {
        path.contains("/.build/debug/") || path.contains("/.build/arm64-apple-macosx/debug/")
    }

    /// Loads the installed LaunchAgent, which starts the daemon. An agent that is already
    /// loaded is booted out first: `launchctl load` alone ignores it, so a re-install (an
    /// upgrade, a new binary path) kept the old daemon running. A failed bootout is fine
    /// when the agent was not loaded; when it still is, this throws instead of loading.
    public static func loadAgent(shell: ShellRunning = Shell()) async throws -> ShellResult {
        let plist = agentPlistPath().path
        let domain = "gui/\(getuid())"
        let bootout = try await shell.run([launchctlPath, "bootout", domain, plist], cwd: nil, timeout: 30)
        if !bootout.succeeded {
            let loaded = try await shell.run([launchctlPath, "print", "\(domain)/\(label)"], cwd: nil, timeout: 30)
            if loaded.succeeded {
                let why = bootout.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
                throw DaemonError.bootoutFailed(why.isEmpty ? "exit \(bootout.exitCode)" : why)
            }
        }
        let bootstrap = try await shell.run(
            [launchctlPath, "bootstrap", domain, plist], cwd: nil, timeout: 30)
        guard bootstrap.succeeded else { return bootstrap }
        let status = try await shell.run(
            [launchctlPath, "print", "\(domain)/\(label)"], cwd: nil, timeout: 30)
        guard status.succeeded, launchAgentStatusIsHealthy(status.stdout) else {
            let detail = status.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            let reason = detail.isEmpty ? status.stdout.trimmingCharacters(in: .whitespacesAndNewlines) : detail
            throw DaemonError.agentStartFailed(reason.isEmpty ? "launchctl did not report a running daemon" : reason)
        }
        return status
    }

    /// launchctl's exit status is not enough: bootstrap can succeed even when
    /// the daemon immediately exits because its binary/config is unusable.
    static func launchAgentStatusIsHealthy(_ output: String) -> Bool {
        guard jobIsRunning(printOutput: output) else { return false }
        guard
            let line = output.split(separator: "\n").map({ $0.trimmingCharacters(in: .whitespaces) })
                .first(where: { $0.hasPrefix("last exit code = ") })
        else { return true }
        let rawCode = line.dropFirst("last exit code = ".count)
        // A fresh job that never exited yet says so; treat that as the
        // healthy zero it stands for (it can only appear on a running agent,
        // which the state check above already required).
        if rawCode == "(never exited)" { return true }
        guard let code = Self.exitCode(from: String(rawCode)) else { return false }
        return code == 0
    }

    /// The exit code in a `last exit code = …` fragment: a plain integer
    /// (`78`), an annotated one (`78: EX_CONFIG`), or nil for anything else —
    /// an unreadable code is not evidence of a healthy agent.
    static func exitCode(from fragment: String) -> Int? {
        if let exact = Int(fragment) { return exact }
        var rest = fragment[...]
        var negative = false
        if rest.first == "-" { negative = true; rest = rest.dropFirst() }
        let numeric = rest.prefix { $0.isNumber }
        guard !numeric.isEmpty else { return nil }
        return Int((negative ? "-" : "") + numeric)
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

    /// Write the LaunchAgent plist pointing at the given kinhin binary. `environment` lands in its
    /// `EnvironmentVariables` on top of whatever the plist already carried there, so a reinstall (an upgrade, a new
    /// binary path) keeps a `TART_HOME` or other variable the agent had.
    public static func installAgent(binaryPath: String, environment: [String: String] = [:]) throws {
        let url = agentPlistPath()
        let merged = existingAgentEnvironment(at: url).merging(environment) { _, new in new }
        let plist = agentPlist(binaryPath: binaryPath, logs: Paths.logsDirectory, environment: merged)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try plist.write(to: url, atomically: true, encoding: .utf8)
        Log.info("daemon", "launchagent written to \(url.path)")
    }

    /// The variables the daemon's LaunchAgent sets for `storage`: `TART_HOME` when `tart_home:` is configured.
    public static func agentEnvironment(for storage: KinhinConfig.StorageConfig) -> [String: String] {
        storage.tartHome.map { [StorageLocations.tartHomeVariable: $0] } ?? [:]
    }

    /// The `EnvironmentVariables` of the plist at `url`; empty when there is no plist or it has none.
    static func existingAgentEnvironment(at url: URL) -> [String: String] {
        guard FileManager.default.fileExists(atPath: url.path) else { return [:] }
        do {
            let data = try Data(contentsOf: url)
            let root = try PropertyListSerialization.propertyList(from: data, options: [], format: nil)
            return (root as? [String: Any])?["EnvironmentVariables"] as? [String: String] ?? [:]
        } catch {
            // The plist is rewritten in full next; an unreadable one only loses its variables, which the log names.
            Log.warn("daemon", "could not read \(url.path) to keep its environment: \(error.localizedDescription)")
            return [:]
        }
    }

    /// The LaunchAgent plist text.
    static func agentPlist(binaryPath: String, logs: URL, environment: [String: String]) -> String {
        let variables =
            environment.isEmpty
            ? ""
            : "    <key>EnvironmentVariables</key>\n    <dict>\n"
                + environment.keys.sorted().map { key in
                    "        <key>\(xmlEscaped(key))</key>\n        <string>\(xmlEscaped(environment[key] ?? ""))</string>\n"
                }.joined()
                + "    </dict>\n"
        return """
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
            \(variables)</dict>
            </plist>
            """
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
            _ = try await shell.run([launchctlPath, "bootout", "gui/\(uid)", plist.path], cwd: nil, timeout: 30)
        }
        do {
            _ = try await shell.run([launchctlPath, "unload", plist.path], cwd: nil, timeout: 30)
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
