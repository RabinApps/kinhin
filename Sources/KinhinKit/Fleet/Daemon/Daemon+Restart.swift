import Foundation

extension Daemon {
    /// Whether a daemon reporting `runningVersion` must restart to run `current`. An older daemon omits its version
    /// (nil), so it always counts as stale. Pure, so the rule is testable without a socket or launchctl.
    static func needsRestart(runningVersion: String?, current: String) -> Bool {
        runningVersion != current
    }

    /// A restart can only upgrade the daemon when the agent runs this app's bundled CLI.
    /// Resolve symlinks so an installed command linking into the app is accepted too.
    static func targetsCurrentBinary(_ installedPath: String?, currentBinaryURL: URL?) -> Bool {
        guard let installedPath, !installedPath.isEmpty, let currentBinaryURL else { return false }
        return launchAgentBinary(argv0: installedPath) == launchAgentBinary(argv0: currentBinaryURL.path)
    }

    /// Whether `launchctl print` output describes a job that is running a process. Its own `state =` line comes
    /// first; later ones belong to nested sections. Pure, so it is testable without launchctl.
    static func jobIsRunning(printOutput: String) -> Bool {
        for line in printOutput.split(separator: "\n") {
            let text = line.trimmingCharacters(in: .whitespaces)
            if text.hasPrefix("state = ") { return text == "state = running" }
        }
        return false
    }

    /// Whether the installed LaunchAgent has a running process. When no daemon answers on the socket, that process is
    /// one still starting (it takes its lock, then verifies every forge before it binds): a launch must wait for it,
    /// not run a second engine beside it, including after the app was reopened mid-restart. False when no agent is
    /// installed or launchctl can't say.
    public static func agentJobIsRunning(shell: ShellRunning = Shell()) async -> Bool {
        guard agentPlistURL != nil else { return false }
        let res: ShellResult
        do {
            res = try await shell.run([launchctlPath, "print", "gui/\(getuid())/\(label)"], cwd: nil, timeout: 30)
        } catch {
            return false  // launchctl can't say: treat as no job, the caller falls back as before
        }
        return res.succeeded && jobIsRunning(printOutput: res.stdout)
    }

    /// After an in-place upgrade the previous build's daemon keeps running its old binary in memory, and nothing
    /// restarts it. Restarts the installed LaunchAgent when a live daemon reports another version, so it runs the
    /// binary the agent points at (the upgraded app's own copy). No LaunchAgent, or no live daemon: nothing to do.
    /// Returns true when it issued a restart.
    @discardableResult
    public static func restartIfStale(shell: ShellRunning = Shell()) async throws -> Bool {
        guard agentPlistURL != nil else { return false }
        let ping: PingReply
        do {
            ping = try await RPCClient().perform { try $0.ping() }
        } catch {
            return false  // no live daemon to restart
        }
        guard needsRestart(runningVersion: ping.version, current: kinhinVersion.current) else { return false }
        guard
            targetsCurrentBinary(
                plistBinaryPath,
                currentBinaryURL: Bundle.main.url(forResource: "kinhin", withExtension: nil, subdirectory: "bin"))
        else { return false }
        Log.info(
            "daemon",
            "daemon runs \(ping.version ?? "an older build"), kinhin is \(kinhinVersion.current); restarting it")
        let res = try await shell.run(
            [launchctlPath, "kickstart", "-k", "gui/\(getuid())/\(label)"], cwd: nil, timeout: 30)
        guard res.succeeded else {
            let why = res.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            throw DaemonError.restartFailed(why.isEmpty ? "exit \(res.exitCode)" : why)
        }
        return true
    }
}
