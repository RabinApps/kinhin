import Foundation

/// Gitea and Forgejo: wire-compatible, so one descriptor serves both and only
/// the id (and with it the display name) differs.
struct GiteaDescriptor: ForgeDescriptor {
    let id: ForgeID
    var displayName: String { id == .forgejo ? "Forgejo" : "Gitea" }
    let isSelfHosted = true
    let scopeHint = "'owner/name' or an org name"
    var agent: RunnerAgentSpec { .gitea }

    func isValidScope(_ scope: String) -> Bool { AccountConfig.isValidScope(scope) }

    func parseAccount(_ entry: ConfigLoader.AccountEntry) throws -> AccountConfig {
        try ConfigLoader.parseGiteaAccount(entry)
    }
}

// MARK: - Runner agent

extension RunnerAgentSpec {
    /// The gitea-runner binary, shared by Gitea and Forgejo.
    static let gitea = RunnerAgentSpec(
        key: "gitea", forges: [.gitea, .forgejo], order: 1, credential: "Gitea token", artifact: "gitea-runner",
        version: { $0.gitea },
        feed: ReleaseFeed(
            name: "Gitea", url: ReleaseFeed.literal("https://gitea.com/api/v1/repos/gitea/runner/releases/latest")),
        bake: Bake(
            macOS: { RunnerBootstrap.giteaRunnerInstallScript(version: $0.gitea) },
            tartLinux: { RunnerBootstrap.tartLinuxGiteaRunnerInstallScript(version: $0.gitea) },
            container: { versions, platform in
                RunnerBootstrap.linuxGiteaRunnerInstallScript(version: versions.gitea, arch: platform.giteaRunnerArch)
            }),
        host: HostAgentSpec(
            required: true, installedPath: "gitea-runner", mustBeExecutable: true, missingWhat: "gitea-runner",
            missingLocation: "", summaryName: "gitea-runner",
            installScript: { versions, arm64, _ in
                """
                \(RunnerBootstrap.giteaRunnerDownloadScript(version: versions.gitea, platform: arm64 ? "darwin-arm64" : "darwin-amd64", file: "runner.xz"))
                xz -d runner.xz
                chmod +x runner
                mv runner gitea-runner
                """
            }))
}
