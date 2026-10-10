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

    func registrationScript(for guest: RegistrationGuest, _ request: RegistrationRequest) throws -> String {
        let forge = request.forge
        let tags = RunnerBootstrap.buildkiteTags(accountLabels: forge.labels, poolLabels: request.labels)
        let runnerNames = FleetEngine.runnerNames(for: request.name, count: request.runnerCount)
        switch guest {
        case .tartVM:
            return RunnerBootstrap.buildkiteRegistrationScript(
                token: request.token, tags: tags, runnerNames: runnerNames, ephemeral: request.route.ephemeral,
                binary: "\"$HOME/buildkite-agent/buildkite-agent\"", baseDir: "\"$HOME/buildkite-agent\"")
        case .linuxContainer:
            return RunnerBootstrap.buildkiteRegistrationScript(
                token: request.token, tags: tags, runnerNames: runnerNames, ephemeral: request.route.ephemeral,
                binary: "/opt/buildkite-agent/buildkite-agent", baseDir: "/opt/buildkite-agent")
        case .host(let host):
            return host.buildkiteRegistrationScript(
                forge: forge, token: request.token, name: request.name, runnerCount: request.runnerCount,
                labels: request.labels)
        }
    }

    func makeForge(_ build: ForgeBuild) async throws -> any Forge {
        let account = build.account
        return try await BuildkiteForge.make(
            credentials: BuildkiteCredentials(token: build.token, scope: account.scope),
            labels: account.labels ?? BuildkiteForge.defaultLabels,
            account: account.name
        )
    }

    func makeAdmin(account: AccountConfig, token: String) -> any ForgeAdmin {
        ClosureForgeAdmin(
            check: { await TokenHealthCheck.buildkite(token: token, scope: account.scope) },
            scopes: {
                try await BuildkiteClient(credentials: BuildkiteCredentials(token: token, scope: "")).listScopes()
            })
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
            stop: { await $0.stopBuildkiteAgents(id: $1) },
            installScript: { versions, arm64, _ in
                """
                \(RunnerBootstrap.buildkiteAgentDownloadScript(version: versions.buildkite, platform: arm64 ? "darwin-arm64" : "darwin-amd64", file: "buildkite-agent.tar.gz"))
                \(RunnerBootstrap.buildkiteAgentExtractScript(archive: "buildkite-agent.tar.gz"))
                """
            }))
}
