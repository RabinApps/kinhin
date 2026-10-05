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
    /// its `gitlab-runner run-single` child.
    func stopGitLabRunners(id: String) async {
        await stopRecordedAgents(id: id, pidFile: "runner.pid", command: "run-single", what: "gitlab runners")
    }
}
