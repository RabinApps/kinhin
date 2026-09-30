import Foundation

// MARK: - Buildkite on the host

extension HostRuntime {
    /// The Buildkite agent binary installed by `HostAgentInstaller`.
    var buildkiteAgentBinary: URL { agentDir.appendingPathComponent("buildkite-agent") }

    /// Buildkite registration on the Mac itself: each agent's builds,
    /// plugins, token file, log and pid live in `<instance work dir>/<runner
    /// name>`, so teardown's scrub removes them with the instance. Host
    /// agents always leave after one job.
    func buildkiteRegistrationScript(forge: Forge, token: String, name: String, runnerCount: Int, labels: [String]?)
        -> String
    {
        RunnerBootstrap.buildkiteRegistrationScript(
            token: token,
            tags: RunnerBootstrap.buildkiteTags(accountLabels: forge.labels, poolLabels: labels),
            runnerNames: FleetEngine.runnerNames(for: name, count: runnerCount),
            binary: RunnerBootstrap.shellQuote(buildkiteAgentBinary.path),
            baseDir: RunnerBootstrap.shellQuote(workDirectory(for: name).path))
    }

    /// Stops this instance's Buildkite agents that are still connected (a
    /// scale-down or engine stop mid-job).
    func stopBuildkiteAgents(id: String) async {
        await stopRecordedAgents(id: id, pidFile: "agent.pid", command: "buildkite-agent", what: "buildkite agents")
    }
}
