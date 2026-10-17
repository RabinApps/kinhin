import Foundation

extension Daemon {
    /// Whether a daemon reporting `runningVersion` must restart to run `current`. An older daemon omits its version
    /// (nil), so it always counts as stale. Pure, so the rule is testable without a socket or launchctl.
    static func needsRestart(runningVersion: String?, current: String) -> Bool {
        runningVersion != current
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
