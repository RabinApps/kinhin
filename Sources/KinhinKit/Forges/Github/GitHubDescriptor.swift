import Foundation

struct GitHubDescriptor: ForgeDescriptor {
    let id: ForgeID = .github
    let displayName = "GitHub"
    let isSelfHosted = false
    let scopeHint = "'owner/name' or an org name"
    var agent: RunnerAgentSpec { .github }

    func isValidScope(_ scope: String) -> Bool { AccountConfig.isValidScope(scope) }

    func parseAccount(_ entry: ConfigLoader.AccountEntry) throws -> AccountConfig {
        try ConfigLoader.parseGitHubAccount(entry)
    }
}

// MARK: - Runner agent

extension RunnerAgentSpec {
    /// GitHub's actions-runner.
    static let github = RunnerAgentSpec(
        key: "github", forges: [.github], order: 0, credential: "GitHub PAT", artifact: "actions-runner",
        version: { $0.github },
        feed: ReleaseFeed(
            name: "GitHub", url: ReleaseFeed.literal("https://api.github.com/repos/actions/runner/releases/latest")),
        bake: Bake(
            macOS: { RunnerBootstrap.installScript(runnerVersion: $0.github) },
            tartLinux: { RunnerBootstrap.tartLinuxGitHubAgentInstallScript(runnerVersion: $0.github) },
            container: { versions, platform in
                RunnerBootstrap.linuxGitHubAgentInstallScript(
                    version: versions.github, arch: platform.githubRunnerArch)
            }),
        host: HostAgentSpec(
            required: true, installedPath: "config.sh", mustBeExecutable: false, missingWhat: "config.sh",
            missingLocation: "", summaryName: "actions-runner",
            installScript: { versions, arm64, _ in
                """
                \(RunnerBootstrap.githubRunnerDownloadScript(version: versions.github, platform: arm64 ? "osx-arm64" : "osx-x64", file: "runner.tar.gz"))
                tar xzf runner.tar.gz
                rm runner.tar.gz
                """
            }))
}
