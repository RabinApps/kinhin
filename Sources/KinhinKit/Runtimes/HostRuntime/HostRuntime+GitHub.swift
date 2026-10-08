import Foundation

// MARK: - GitHub on the host

extension HostRuntime {
    /// The GitHub registration script: a scale-set (JIT) runner per name, or
    /// the classic ephemeral registration, run from the agent directory with
    /// the work directory redirected into the instance's scrubbed dir. Labels:
    /// the pool's labels (already merged with `kinhin-host` at pool build).
    func githubRegistrationScript(_ request: RegistrationRequest) throws -> String {
        let forge = request.forge
        let name = request.name
        let runnerCount = request.runnerCount
        let runnerTokens = request.runnerTokens
        if case .jitConfig = forge.registration {
            let workDir = workDirectory(for: name)
            try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
            let names = FleetEngine.runnerNames(for: name, count: runnerCount)
            guard names.allSatisfy({ runnerTokens[$0] != nil }), runnerTokens.count == names.count else {
                throw EngineError.registrationFailed(vm: name, stderr: "forge returned incomplete JIT configs")
            }
            let blocks = names.enumerated().map { index, runnerName in
                let runnerDirectory =
                    runnerCount == 1
                    ? agentDir
                    : agentDir.deletingLastPathComponent().appendingPathComponent("host-runner-\(index + 1)")
                let pidFile = workDir.appendingPathComponent(runnerName).appendingPathComponent("runner.pid")
                return """
                    set -euo pipefail
                    mkdir -p \(RunnerBootstrap.shellQuote(runnerDirectory.path))
                    mkdir -p \(RunnerBootstrap.shellQuote(pidFile.deletingLastPathComponent().path))
                    if [ ! -x \(RunnerBootstrap.shellQuote(runnerDirectory.appendingPathComponent("config.sh").path)) ]; then
                      cp -a \(RunnerBootstrap.shellQuote(agentDir.path + "/.")) \(RunnerBootstrap.shellQuote(runnerDirectory.path + "/"))
                    fi
                    \(RunnerBootstrap.jitRegistrationScript(
                        encodedJitConfig: runnerTokens[runnerName] ?? "", name: runnerName,
                        workFolder: workDir.appendingPathComponent(runnerName).path,
                        agentDirectory: runnerDirectory.path,
                        pidFile: pidFile.path
                    ))
                    """
            }
            return blocks.joined(separator: "\n")
        }
        let workDir = workDirectory(for: name)
        let base = RunnerBootstrap.registrationScript(
            configureURL: forge.registrationURL(),
            token: request.token,
            labels: request.labels ?? forge.labels,
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

    /// Stops scale-set runner processes recorded in the instance work dir.
    func stopGitHubRunners(id: String) async {
        await stopRecordedAgents(
            id: id, pidFile: "runner.pid", command: "Runner.Listener", what: "GitHub runners")
    }
}
