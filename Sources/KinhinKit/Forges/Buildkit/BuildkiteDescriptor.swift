import Foundation

struct BuildkiteDescriptor: ForgeDescriptor {
    let id: ForgeID = .buildkite
    let displayName = "Buildkite"
    let isSelfHosted = false
    let scopeHint = "'org-slug/cluster' (the cluster's name or id)"
    var agent: RunnerAgentSpec { .buildkite }

    func isValidScope(_ scope: String) -> Bool { BuildkiteCredentials.isValidScope(scope) }

    /// A cluster covers many repositories.
    func isSingleRepositoryScope(_ scope: String) -> Bool { false }

    func parseAccount(_ entry: ConfigLoader.AccountEntry) throws -> AccountConfig {
        try ConfigLoader.parseBuildkiteAccount(entry)
    }
}

// MARK: - Runner agent

extension RunnerAgentSpec {
    /// The buildkite-agent binary.
    static let buildkite = RunnerAgentSpec(
        key: "buildkite", forges: [.buildkite], order: 3, credential: "Buildkite token",
        artifact: "buildkite-agent", version: { $0.buildkite },
        feed: ReleaseFeed(
            name: "Buildkite", url: ReleaseFeed.literal("https://api.github.com/repos/buildkite/agent/releases/latest"),
            excludesDashes: true),
        bake: Bake(
            macOS: { RunnerBootstrap.buildkiteAgentInstallScript(version: $0.buildkite) },
            tartLinux: { RunnerBootstrap.tartLinuxBuildkiteAgentInstallScript(version: $0.buildkite) },
            container: { versions, platform in
                RunnerBootstrap.linuxBuildkiteAgentInstallScript(
                    version: versions.buildkite, arch: platform.buildkiteAgentArch)
            }),
        host: HostAgentSpec(
            required: false, installedPath: "buildkite-agent", mustBeExecutable: true,
            missingWhat: "buildkite-agent", missingLocation: "", summaryName: "buildkite-agent",
            installScript: { versions, arm64, _ in
                """
                \(RunnerBootstrap.buildkiteAgentDownloadScript(version: versions.buildkite, platform: arm64 ? "darwin-arm64" : "darwin-amd64", file: "buildkite-agent.tar.gz"))
                tar xzf buildkite-agent.tar.gz ./buildkite-agent
                rm buildkite-agent.tar.gz
                """
            }))
}
