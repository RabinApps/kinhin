import Foundation

struct GitLabDescriptor: ForgeDescriptor {
    let id: ForgeID = .gitlab
    let displayName = "GitLab"
    let isSelfHosted = true
    let scopeHint = "a GitLab project or group path (e.g. 'group/project')"
    var agent: RunnerAgentSpec { .gitlab }

    func isValidScope(_ scope: String) -> Bool { GitLabCredentials.isValidScope(scope) }

    /// GitLab paths nest; only a project path (group/project) names one project,
    /// and it is indistinguishable from a subgroup, so require two or more segments.
    func isSingleRepositoryScope(_ scope: String) -> Bool { scope.split(separator: "/").count >= 2 }

    func parseAccount(_ entry: ConfigLoader.AccountEntry) throws -> AccountConfig {
        try ConfigLoader.parseGitLabAccount(entry)
    }
}

// MARK: - Runner agent

extension RunnerAgentSpec {
    /// The gitlab-runner binary.
    static let gitlab = RunnerAgentSpec(
        key: "gitlab", forges: [.gitlab], order: 2, credential: "GitLab token", artifact: "gitlab-runner",
        version: { $0.gitlab },
        feed: ReleaseFeed(
            name: "GitLab",
            url: ReleaseFeed.literal(
                "https://gitlab.com/api/v4/projects/gitlab-org%2Fgitlab-runner/releases/permalink/latest"),
            excludesDashes: true),
        bake: Bake(
            macOS: { RunnerBootstrap.gitlabRunnerInstallScript(version: $0.gitlab) },
            tartLinux: { RunnerBootstrap.tartLinuxGitLabRunnerInstallScript(version: $0.gitlab) },
            container: { versions, platform in
                RunnerBootstrap.linuxGitLabRunnerInstallScript(
                    version: versions.gitlab, arch: platform.gitlabRunnerArch)
            }),
        host: HostAgentSpec(
            required: false, installedPath: "gitlab-runner", mustBeExecutable: true, missingWhat: "gitlab-runner",
            missingLocation: "", summaryName: "gitlab-runner",
            installScript: { versions, arm64, _ in
                """
                \(RunnerBootstrap.gitlabRunnerDownloadScript(version: versions.gitlab, platform: arm64 ? "darwin-arm64" : "darwin-amd64", file: "gitlab-runner"))
                chmod +x gitlab-runner
                """
            }))
}
