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

    func registrationScript(for guest: RegistrationGuest, _ request: RegistrationRequest) throws -> String {
        func runners() throws -> [(name: String, bundle: String)] {
            try RunnerBootstrap.bitbucketRunners(
                name: request.name, runnerCount: request.runnerCount, tokens: request.runnerTokens)
        }
        switch guest {
        case .tartVM:
            // A tart base VM may be a macOS or a Linux guest; `auto` lets the
            // guest resolve its own --runtime (Darwin -> macos, else linux-shell).
            return RunnerBootstrap.bitbucketRegistrationScript(
                runners: try runners(), runtime: "auto", runnerCommand: "\"$HOME/bitbucket-runner/runner.sh\"",
                baseDir: "\"$HOME/bitbucket-runners\"")
        case .linuxContainer:
            return RunnerBootstrap.bitbucketRegistrationScript(
                runners: try runners(), runtime: "linux-shell", runnerCommand: "/opt/bitbucket-runner/runner.sh",
                baseDir: "/opt/bitbucket-runners")
        case .host(let host):
            return try host.bitbucketRegistrationScript(
                forge: request.forge, runnerTokens: request.runnerTokens, name: request.name,
                runnerCount: request.runnerCount)
        }
    }

    func makeForge(_ build: ForgeBuild) async throws -> any Forge {
        let account = build.account
        return try await BitbucketForge.make(
            credentials: BitbucketCredentials(token: build.token, scope: account.scope),
            labels: account.labels ?? [],
            account: account.name
        )
    }

    func makeAdmin(account: AccountConfig, token: String) -> any ForgeAdmin {
        ClosureForgeAdmin(
            check: { await TokenHealthCheck.bitbucket(token: token, scope: account.scope) },
            scopes: {
                try await BitbucketClient(credentials: BitbucketCredentials(token: token, scope: "")).listScopes()
            })
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
            stop: { await $0.stopBitbucketRunners(id: $1) },
            installScript: { versions, arm64, agentDir in
                // The macOS runner (package + bundled JDK) each host runner uses.
                RunnerBootstrap.bitbucketRunnerInstallScript(
                    version: versions.bitbucket, jdkVersion: versions.bitbucketJDK,
                    jdkPlatform: arm64 ? "aarch64_mac" : "x64_mac"
                )
                .replacingOccurrences(of: "$HOME", with: agentDir.path)
            }))
}
