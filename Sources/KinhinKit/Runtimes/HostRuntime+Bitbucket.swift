import Foundation

// MARK: - Bitbucket on the host

extension HostRuntime {
    /// Bitbucket registration on the Mac itself: each runner's build
    /// directories, credential file, log and pid live in `<instance work
    /// dir>/<runner name>`, so teardown's scrub removes them with the
    /// instance.
    func bitbucketRegistrationScript(
        forge: Forge, runnerTokens: [String: String], name: String, runnerCount: Int
    ) throws -> String {
        RunnerBootstrap.bitbucketRegistrationScript(
            runners: try RunnerBootstrap.bitbucketRunners(
                name: name, runnerCount: runnerCount, tokens: runnerTokens),
            runtime: "macos",
            runnerCommand: RunnerBootstrap.shellQuote(
                agentDir.appendingPathComponent("bitbucket-runner/runner.sh").path),
            baseDir: RunnerBootstrap.shellQuote(workDirectory(for: name).path))
    }

    /// Stops this instance's Bitbucket runners that have not finished their
    /// step (a scale-down or engine stop mid-job).
    func stopBitbucketRunners(id: String) async {
        await stopRecordedAgents(id: id, pidFile: "runner.pid", command: "runner.sh", what: "bitbucket runners")
    }
}
