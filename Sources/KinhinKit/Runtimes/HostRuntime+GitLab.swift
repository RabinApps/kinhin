import Foundation

// MARK: - GitLab on the host

extension HostRuntime {
    /// The GitLab agent binary installed by `HostAgentInstaller`.
    var gitlabRunnerBinary: URL { agentDir.appendingPathComponent("gitlab-runner") }

    /// GitLab registration on the Mac itself: each runner's builds, cache,
    /// token file, log and pid live in `<instance work dir>/<runner name>`,
    /// so teardown's scrub removes them with the instance.
    func gitlabRegistrationScript(forge: Forge, runnerTokens: [String: String], name: String, runnerCount: Int)
        throws -> String
    {
        RunnerBootstrap.gitlabRegistrationScript(
            instance: forge.registrationURL(),
            runners: try RunnerBootstrap.gitlabRunners(name: name, runnerCount: runnerCount, tokens: runnerTokens),
            binary: RunnerBootstrap.shellQuote(gitlabRunnerBinary.path),
            baseDir: RunnerBootstrap.shellQuote(workDirectory(for: name).path))
    }

    /// Stops this instance's GitLab runners that have not finished their job
    /// (a scale-down or engine stop mid-job): the recorded background job and
    /// its `gitlab-runner run-single` child. A pid is only signalled while it
    /// still looks like ours (pids get reused).
    func stopGitLabRunners(id: String) async {
        let workDir = workDirectory(for: id)
        // No runner.pid means no GitLab runner was started here (an absent
        // dir, or another forge's instance), so there is nothing to stop.
        let fm = FileManager.default
        // A missing or unreadable dir holds no runners to stop.
        let entries = (try? fm.contentsOfDirectory(atPath: workDir.path)) ?? []
        guard
            entries.contains(where: {
                fm.fileExists(atPath: workDir.appendingPathComponent($0).appendingPathComponent("runner.pid").path)
            })
        else { return }
        let script = """
            for f in \(RunnerBootstrap.shellQuote(workDir.path))/*/runner.pid; do
              [ -f "$f" ] || continue
              pid="$(cat "$f")"
              if ps -p "$pid" -o command= | grep -q 'run-single'; then
                pkill -TERM -P "$pid" || true
                kill "$pid" || true
              fi
            done
            """
        await bestEffortAsync(id, "stopping gitlab runners") {
            _ = try await shell.run(["/bin/bash", "-c", script], cwd: nil, timeout: 30)
        }
    }
}
