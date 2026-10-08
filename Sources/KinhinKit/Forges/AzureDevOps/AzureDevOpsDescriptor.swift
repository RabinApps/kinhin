import Foundation

struct AzureDevOpsDescriptor: ForgeDescriptor {
    let id: ForgeID = .azuredevops
    let displayName = "Azure DevOps"
    let isSelfHosted = true
    let scopeHint = "the agent pool's name"
    var agent: RunnerAgentSpec { .azure }

    func isValidScope(_ scope: String) -> Bool { AzureDevOpsCredentials.isValidScope(scope) }

    /// A pool covers many repositories.
    func isSingleRepositoryScope(_ scope: String) -> Bool { false }

    func parseAccount(_ entry: ConfigLoader.AccountEntry) throws -> AccountConfig {
        try ConfigLoader.parseAzureDevOpsAccount(entry)
    }

    func registrationScript(for guest: RegistrationGuest, _ request: RegistrationRequest) throws -> String {
        let forge = request.forge
        let runnerNames = FleetEngine.runnerNames(for: request.name, count: request.runnerCount)
        let capabilities = AzureDevOpsForge.capabilityEnvironment(forge.labels)
        switch guest {
        case .tartVM:
            return RunnerBootstrap.azureRegistrationScript(
                organization: forge.registrationURL(), token: request.token, pool: forge.scope,
                runnerNames: runnerNames, capabilities: capabilities,
                template: "\"$HOME/azure-agent\"", baseDir: "\"$HOME/azure-agents\"", copy: .vmGuest)
        case .linuxContainer:
            // Containers run as root, which the agent refuses unless allowed.
            return RunnerBootstrap.azureRegistrationScript(
                organization: forge.registrationURL(), token: request.token, pool: forge.scope,
                runnerNames: runnerNames, capabilities: capabilities,
                template: "/opt/azure-agent", baseDir: "/opt/azure-agents", copy: .archive,
                extraEnvironment: ["AGENT_ALLOW_RUNASROOT=1"])
        case .host(let host):
            return host.azureRegistrationScript(
                forge: forge, token: request.token, name: request.name, runnerCount: request.runnerCount)
        }
    }

    func makeForge(_ build: ForgeBuild) async throws -> any Forge {
        let account = build.account
        guard let instance = account.instance else {
            throw EngineError.accountUnverified("no organization URL configured")
        }
        return try await AzureDevOpsForge.make(
            credentials: AzureDevOpsCredentials(
                token: build.token, scope: account.scope, instance: instance,
                allowInsecureHTTP: account.allowInsecureHTTP ?? false),
            labels: account.labels ?? [],
            account: account.name
        )
    }

    func makeAdmin(account: AccountConfig, token: String) -> any ForgeAdmin {
        ClosureForgeAdmin(
            check: {
                guard let instance = account.instance, !instance.isEmpty else {
                    return TokenHealthCheck.Report(
                        ok: false, message: "This account has no organization URL in config.yaml.")
                }
                return await TokenHealthCheck.azureDevOps(
                    token: token, scope: account.scope, instance: instance,
                    allowInsecureHTTP: account.allowInsecureHTTP ?? false)
            },
            scopes: {
                try await AzureDevOpsClient(
                    credentials: AzureDevOpsCredentials(
                        token: token, scope: "", instance: account.instance ?? "",
                        allowInsecureHTTP: account.allowInsecureHTTP ?? false)
                ).listPools()
            })
    }
}

// MARK: - Runner agent

extension RunnerAgentSpec {
    /// The Azure Pipelines agent.
    static let azure = RunnerAgentSpec(
        key: "azure", forges: [.azuredevops], order: 4, credential: "Azure DevOps token",
        artifact: "the Azure Pipelines agent", version: { $0.azure },
        feed: ReleaseFeed(
            name: "Azure Pipelines",
            url: ReleaseFeed.literal("https://api.github.com/repos/microsoft/azure-pipelines-agent/releases/latest"),
            excludesDashes: true),
        bake: Bake(
            macOS: { RunnerBootstrap.azureAgentInstallScript(version: $0.azure) },
            tartLinux: { RunnerBootstrap.tartLinuxAzureAgentInstallScript(version: $0.azure) },
            container: { versions, platform in
                RunnerBootstrap.linuxAzureAgentInstallScript(
                    version: versions.azure, platform: platform.azureAgentPlatform)
            }),
        host: HostAgentSpec(
            required: false, installedPath: "azure-agent/config.sh", mustBeExecutable: true,
            missingWhat: "the Azure Pipelines agent", missingLocation: "/azure-agent",
            summaryName: "azure pipelines agent",
            stop: { await $0.stopAzureAgents(id: $1) },
            installScript: { versions, arm64, _ in
                // The template each host runner clones (see HostRuntime+AzureDevOps).
                """
                mkdir -p azure-agent
                (
                  cd azure-agent
                  \(RunnerBootstrap.azureAgentDownloadScript(version: versions.azure, platform: arm64 ? "osx-arm64" : "osx-x64", file: "agent.tar.gz").replacingOccurrences(of: "\n", with: "\n  "))
                  tar xzf agent.tar.gz
                  rm agent.tar.gz
                )
                """
            }))
}
