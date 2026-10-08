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

    func makeForge(_ build: ForgeBuild) async throws -> any Forge {
        let account = build.account
        let credentials = GitHubCredentials(
            token: build.token, scope: account.scope, instance: account.instance,
            allowInsecureHTTP: account.allowInsecureHTTP ?? false)
        let client = build.githubClient(credentials)
        if build.verify {
            let verification = await OrgPermissionProbe.verify(github: client, scope: account.scope)
            guard verification.ok else {
                throw EngineError.accountUnverified(verification.message)
            }
        }
        if let scaleSet = account.scaleSet {
            let targets = await build.scaleSetTargets(client, scaleSet)
            return GitHubScaleSetForge(
                account: account, token: build.token, client: client,
                labels: account.labels ?? build.fleetLabels, targets: targets)
        }
        return GitHubForge(account: account, token: build.token, client: client, labels: build.fleetLabels)
    }

    func makeAdmin(account: AccountConfig, token: String) -> any ForgeAdmin {
        makeAdmin(account: account, token: token, client: nil)
    }

    /// `client` replaces the live GitHub client for the token check (tests).
    func makeAdmin(account: AccountConfig, token: String, client: GitHubServing?) -> any ForgeAdmin {
        ClosureForgeAdmin(
            check: {
                guard !account.scope.isEmpty else {
                    return TokenHealthCheck.Report(
                        ok: false, message: "No scope to check — add a GitHub account to config.yaml first.")
                }
                return await TokenHealthCheck.github(
                    token: token, scope: account.scope, instance: account.instance,
                    allowInsecureHTTP: account.allowInsecureHTTP ?? false, account: account.name, client: client)
            },
            scopes: {
                try await GitHubClient(
                    credentials: GitHubCredentials(
                        token: token, scope: "", instance: account.instance,
                        allowInsecureHTTP: account.allowInsecureHTTP ?? false)
                ).listRepositories()
            })
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
            stop: { await $0.stopGitHubRunners(id: $1) },
            installScript: { versions, arm64, _ in
                """
                \(RunnerBootstrap.githubRunnerDownloadScript(version: versions.github, platform: arm64 ? "osx-arm64" : "osx-x64", file: "runner.tar.gz"))
                tar xzf runner.tar.gz
                rm runner.tar.gz
                """
            }))
}
