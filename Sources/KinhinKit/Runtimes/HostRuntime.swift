import Foundation

// MARK: - Host runtime (stage 4)

/// Direct execution on the host Mac — the third execution backend, for
/// explicitly trusted repos. No isolation whatsoever: jobs run with the
/// user's privileges, so every route into this pool must carry an explicit
/// `consent: true` (enforced by config validation) and registers with the
/// `kinhin-host` label so only opted-in workflows can land here.
///
/// Ephemeral semantics without VMs: the runner *process* is ephemeral
/// (`--ephemeral` deregistration, same as GitHub-on-Tart) while the machine
/// stays warm. Each instance gets its own work directory under kinhin's
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

    // MARK: Runtime protocol

    func health() async -> RuntimeHealth {
        let agent = agentDir.appendingPathComponent("config.sh")
        guard FileManager.default.fileExists(atPath: agent.path) else {
            return .missing(
                tool: "host runner agent",
                fix: "kinhin setup repair host-agent (installs the actions-runner agent on this Mac)")
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
        try await shell.run(["/bin/bash", "-c", script], cwd: agentDir, timeout: timeout)
    }

    func existingInstanceIDs() async -> [String] {
        let fm = FileManager.default
        let base = Paths.appSupport.appendingPathComponent("host-instances", isDirectory: true)
        guard let entries = try? fm.contentsOfDirectory(atPath: base.path) else { return [] }
        // Instance dirs are named exactly like the records ("kinhin-…").
        return entries.filter { $0.hasPrefix("kinhin-") }
    }

    /// The GitHub registration script, run from the agent directory with the
    /// work directory redirected into the instance's scrubbed dir. Labels:
    /// the pool's labels (already merged with `kinhin-host` at pool build).
    func registrationScript(
        forge: Forge, token: String, name: String,
        runnerCount: Int, route: RepoRoute, labels: [String]?
    ) async throws -> String {
        guard case .github = forge.credentials else {
            throw EngineError.registrationFailed(
                vm: name, stderr: "host mode supports GitHub repos only (Gitea/Forgejo agents need a VM or container)")
        }
        let workDir = workDirectory(for: name)
        let base = RunnerBootstrap.registrationScript(
            configureURL: forge.registrationURL(),
            token: token,
            labels: labels ?? forge.labels,
            ephemeral: true,  // host runners are always ephemeral processes
            name: name,
            runnerCount: runnerCount
        )
        // Run inside the agent dir with the per-instance work dir; the
        // classic script's `cd ~/actions-runner` is overridden up front.
        return """
            set -euo pipefail
            cd \(RunnerBootstrap.shellQuote(agentDir.path))
            mkdir -p \(RunnerBootstrap.shellQuote(workDir.path))
            \(base)
            """
            .replacingOccurrences(of: "cd ~/actions-runner\n", with: "")
            .replacingOccurrences(of: "--work _work", with: "--work \(RunnerBootstrap.shellQuote(workDir.path))")
    }

    /// Engine-owned watch works unchanged (ephemeral deregistration
    /// semantics, same as GitHub-on-Tart).
    func watchExit(id: String, forge: Forge, runnerCount: Int, route: RepoRoute) async throws {}

    /// Deregisters any leftover runner (best-effort) and scrubs the work dir.
    /// Idempotent: missing dirs are already clean.
    func teardown(id: String) async {
        let workDir = workDirectory(for: id)
        await bestEffortAsync(id, "removing host work directory") {
            if FileManager.default.fileExists(atPath: workDir.path) {
                try FileManager.default.removeItem(at: workDir)
            }
        }
    }

    // MARK: Helpers

    /// Per-instance scratch dir, scrubbed at teardown.
    private func workDirectory(for id: String) -> URL {
        Paths.appSupport.appendingPathComponent("host-instances/\(id)", isDirectory: true)
    }
}
