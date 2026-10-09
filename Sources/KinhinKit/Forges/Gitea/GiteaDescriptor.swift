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

    /// Forgejo shares Gitea's runner binary and registration flow.
    func registrationScript(for guest: RegistrationGuest, _ request: RegistrationRequest) throws -> String {
        let forge = request.forge
        // The pool's labels (with its `kinhin-docker`-style marker) win over the account's own.
        let labels = request.labels ?? forge.labels
        switch guest {
        case .tartVM:
            return RunnerBootstrap.linuxGiteaRegistrationScript(
                instance: forge.registrationURL(), token: request.token, labels: labels, name: request.name,
                runnerCount: request.runnerCount, agentDirectory: "$HOME/gitea-runner")
        case .linuxContainer:
            return RunnerBootstrap.linuxGiteaRegistrationScript(
                instance: forge.registrationURL(), token: request.token, labels: labels, name: request.name,
                runnerCount: request.runnerCount)
        case .host(let host):
            return host.giteaRegistrationScript(
                instance: forge.registrationURL(), token: request.token, labels: labels, name: request.name,
                runnerCount: request.runnerCount)
        }
    }

    func makeForge(_ build: ForgeBuild) async throws -> any Forge {
        let account = build.account
        guard let instance = account.instance else {
            throw EngineError.accountUnverified("no instance URL configured")
        }
        return try await GiteaForge.make(
            forge: account.forge,
            credentials: GiteaCredentials(
                token: build.token, scope: account.scope, instance: instance,
                allowInsecureHTTP: account.allowInsecureHTTP ?? false),
            labels: account.labels ?? ["macos:host"],
            demandFloor: build.minRunners,
            account: account.name
        )
    }

    func makeAdmin(account: AccountConfig, token: String) -> any ForgeAdmin {
        ClosureForgeAdmin(
            check: {
                guard let instance = account.instance, !instance.isEmpty else {
                    return TokenHealthCheck.Report(
                        ok: false, message: "This account has no server address in config.yaml.")
                }
                return await TokenHealthCheck.gitea(
                    token: token, scope: account.scope, instance: instance,
                    allowInsecureHTTP: account.allowInsecureHTTP ?? false)
            },
            scopes: {
                try await GiteaClient(
                    credentials: GiteaCredentials(
                        token: token, scope: "", instance: account.instance ?? "",
                        allowInsecureHTTP: account.allowInsecureHTTP ?? false)
                ).listRepositories()
            })
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
            stop: { await $0.stopGiteaDaemons(id: $1) },
            installScript: { versions, arm64, _ in
                """
                \(RunnerBootstrap.giteaRunnerDownloadScript(version: versions.gitea, platform: arm64 ? "darwin-arm64" : "darwin-amd64", file: "runner.xz"))
                xz -d --no-sparse runner.xz
                chmod +x runner
                mv runner gitea-runner
                """
            }))
}
