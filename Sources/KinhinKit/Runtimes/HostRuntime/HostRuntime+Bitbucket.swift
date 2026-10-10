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
    /// step (a scale-down or engine stop mid-job). `runner.sh` and `start.sh`
    /// `exec` into the JVM, so the recorded pid's command line no longer
    /// names the wrapper; it does carry the `--workingDirectory` argument,
    /// which is unique to this instance (`<work dir>/<runner>/work`).
    func stopBitbucketRunners(id: String) async {
        await stopRecordedAgents(
            id: id, pidFile: "runner.pid", command: "--workingDirectory \(workDirectory(for: id).path)/",
            what: "bitbucket runners")
    }
}
