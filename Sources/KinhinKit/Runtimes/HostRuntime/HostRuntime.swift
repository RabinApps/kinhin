import Foundation

// MARK: - Host runtime

/// Direct execution on the host Mac — the third execution backend, for
/// explicitly trusted repos. No isolation whatsoever: jobs run with the
/// user's privileges, so every route into this pool must carry an explicit
/// `consent: true` (enforced by config validation) and registers with the
/// `kinhin-host` label so only opted-in workflows can land here.
///
/// Ephemeral semantics without VMs: the runner *process* is ephemeral
/// (GitHub `--ephemeral` deregistration; Gitea daemons are stopped by
/// teardown once the engine sees the job finish) while the machine stays warm. Each instance gets its own work directory under kinhin's
/// support dir, scrubbed at teardown so job state never outlives the record.
final class HostRuntime: Runtime {
    let id: RuntimeID = .host
    let shell: ShellRunning
    let agentDir: URL

    /// Creates the runtime. `agentDir` is where the GitHub actions-runner
    /// agent lives (~/Library/Application Support/Kinhin/host-runner);
    /// injectable so tests run hermetically.
    init(shell: ShellRunning = Shell(), agentDir: URL? = nil) {
        self.shell = shell
        self.agentDir = agentDir ?? Self.defaultAgentDir
    }

    /// ~/Library/Application Support/Kinhin/host-runner
    static var defaultAgentDir: URL {
        Paths.appSupport.appendingPathComponent("host-runner", isDirectory: true)
    }

    // MARK: - Runtime protocol

    func health() async -> RuntimeHealth {
        guard HostAgentInstaller(shell: shell, agentDir: agentDir).isInstalled else {
            return .missing(
                tool: "host runner agents",
                fix: "kinhin setup repair host-agent (installs the GitHub and Gitea runner agents on this Mac)")
        }
        return .ready
    }

    /// Nothing to provision — the "instance" is a work directory on the host.
    func provision(id: String, route: RepoRoute) async throws {
        let workDir = workDirectory(for: id)
        try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
        Log.info(id, "host work directory ready at \(workDir.path)")
    }

    /// Local exec transport: no address to dial.
    func awaitReady(id: String, timeout: TimeInterval) async throws -> String? {
        nil
    }

    /// Runs the registration script with `bash` on the host itself.
    func execRegistration(_ id: String, ip: String?, _ script: String, timeout: TimeInterval) async throws
        -> ShellResult
    {
        try await shell.run(["/bin/bash", "-s"], input: Data(script.utf8), cwd: agentDir, timeout: timeout)
    }

    func existingInstanceIDs() async throws -> [String] {
        let fm = FileManager.default
        let base = Paths.appSupport.appendingPathComponent("host-instances", isDirectory: true)
        // No dir yet means no host instances exist; an unreadable one throws
        // (recovery then keeps the host records rather than dropping them).
        guard fm.fileExists(atPath: base.path) else { return [] }
        let entries = try fm.contentsOfDirectory(atPath: base.path)
        // Instance dirs are named exactly like the records ("kinhin-…").
        return entries.filter { $0.hasPrefix(InstanceNaming.prefix) }
    }

    /// The registration script for the forge, from its descriptor (the
    /// per-forge builders live in `HostRuntime+<Forge>`), run from the agent
    /// directory with the work directory redirected into the instance's
    /// scrubbed dir. Labels: the pool's labels (already merged with
    /// `kinhin-host` at pool build).
    func registrationScript(
        forge: Forge, token: String, runnerTokens: [String: String], name: String,
        runnerCount: Int, route: RepoRoute, labels: [String]?
    ) async throws -> String {
        let request = RegistrationRequest(
            forge: forge, token: token, runnerTokens: runnerTokens, name: name, runnerCount: runnerCount,
            route: route, labels: labels)
        return try forge.credentials.forge.descriptor.registrationScript(for: .host(self), request)
    }

    /// Engine-owned watch works unchanged (ephemeral deregistration
    /// semantics, same as GitHub-on-Tart).
    /// Stops any Gitea daemons (they never exit on their own) and scrubs the
    /// work dir. Runner registrations are removed by the engine's forge
    /// cleanup. Idempotent: missing dirs are already clean.
    func teardown(id: String) async {
        let workDir = workDirectory(for: id)
        for agent in RunnerAgentSpec.all { await agent.host.stop(self, id) }
        await bestEffortAsync(id, "removing host work directory") {
            if FileManager.default.fileExists(atPath: workDir.path) {
                try FileManager.default.removeItem(at: workDir)
            }
        }
    }

    // MARK: - Helpers

    /// Stops the background agents an instance recorded in
    /// `<work dir>/<runner>/<pidFile>` (GitLab runners, Buildkite agents) and
    /// their children. A pid is only signalled while its command line still
    /// contains `command`, since pids get reused. A pid file is removed only
    /// once its process is stopped or gone: several agents record the same
    /// `runner.pid` name, so a sweep for one agent must leave another agent's
    /// live pid for that agent's own sweep.
    func stopRecordedAgents(id: String, pidFile: String, command: String, what: String) async {
        let workDir = workDirectory(for: id)
        let fm = FileManager.default
        // A missing or unreadable dir holds no agents to stop.
        let runnerDirs = (try? fm.contentsOfDirectory(atPath: workDir.path)) ?? []
        // No pid file means no such agent was started here (another forge's
        // instance), so there is nothing to stop.
        let pidPaths = runnerDirs.map { workDir.appendingPathComponent($0).appendingPathComponent(pidFile).path }
            .filter { fm.fileExists(atPath: $0) }
        guard !pidPaths.isEmpty else { return }
        let pidList = pidPaths.map(RunnerBootstrap.shellQuote).joined(separator: " ")
        let script = """
            for f in \(pidList); do
              [ -f "$f" ] || continue
              pid="$(cat "$f")"
              if ps -p "$pid" -o command= | grep -qF -e \(RunnerBootstrap.shellQuote(command)); then
                pkill -TERM -P "$pid" || true
                kill "$pid" || true
                rm -f "$f"
              elif ! kill -0 "$pid" 2>/dev/null; then
                rm -f "$f"
              fi
            done
            """
        await bestEffortAsync(id, "stopping \(what)") {
            _ = try await shell.run(["/bin/bash", "-c", script], cwd: nil, timeout: 30)
        }
    }

    /// Per-instance scratch dir, scrubbed at teardown.
    func workDirectory(for id: String) -> URL {
        Paths.appSupport.appendingPathComponent("host-instances/\(id)", isDirectory: true)
    }
}
