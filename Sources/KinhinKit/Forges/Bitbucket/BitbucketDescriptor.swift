import Foundation

struct BitbucketDescriptor: ForgeDescriptor {
    let id: ForgeID = .bitbucket
    let displayName = "Bitbucket"
    let isSelfHosted = false
    let scopeHint = "a workspace slug, or 'workspace/repo-slug' for one repository"
    var agent: RunnerAgentSpec { .bitbucket }

    func isValidScope(_ scope: String) -> Bool { BitbucketCredentials.isValidScope(scope) }

    func parseAccount(_ entry: ConfigLoader.AccountEntry) throws -> AccountConfig {
        try ConfigLoader.parseBitbucketAccount(entry)
    }
}

// MARK: - Runner agent

extension RunnerAgentSpec {
    /// The Bitbucket Pipelines runner (and the JDK it needs). Atlassian
    /// publishes no machine-readable release feed, so the version is pinned.
    static let bitbucket = RunnerAgentSpec(
        key: "bitbucket", forges: [.bitbucket], order: 5, credential: "Bitbucket token",
        artifact: "the Bitbucket runner", version: { $0.bitbucket }, feed: nil,
        bake: Bake(
            macOS: { versions in
                RunnerBootstrap.bitbucketRunnerInstallScript(
                    version: versions.bitbucket, jdkVersion: versions.bitbucketJDK, jdkPlatform: "aarch64_mac")
            },
            tartLinux: { versions in
                RunnerBootstrap.tartLinuxBitbucketRunnerInstallScript(
                    version: versions.bitbucket, jdkVersion: versions.bitbucketJDK)
            },
            container: { versions, _ in
                RunnerBootstrap.linuxBitbucketRunnerInstallScript(
                    version: versions.bitbucket, jdkVersion: versions.bitbucketJDK)
            }),
        host: HostAgentSpec(
            required: false, installedPath: "bitbucket-runner/runner.sh", mustBeExecutable: true,
            missingWhat: "the Bitbucket runner", missingLocation: "/bitbucket-runner",
            summaryName: "bitbucket runner",
            installScript: { versions, arm64, agentDir in
                // The macOS runner (package + bundled JDK) each host runner uses.
                RunnerBootstrap.bitbucketRunnerInstallScript(
                    version: versions.bitbucket, jdkVersion: versions.bitbucketJDK,
                    jdkPlatform: arm64 ? "aarch64_mac" : "x64_mac"
                )
                .replacingOccurrences(of: "$HOME", with: agentDir.path)
            }))
}
