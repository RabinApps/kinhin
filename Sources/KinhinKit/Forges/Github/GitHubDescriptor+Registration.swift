import Foundation

// MARK: - GitHub registration scripts

extension GitHubDescriptor {
    func registrationScript(for guest: RegistrationGuest, _ request: RegistrationRequest) throws -> String {
        switch guest {
        case .tartVM: return try tartScript(request)
        case .linuxContainer: return try containerScript(request)
        case .host(let host): return try host.githubRegistrationScript(request)
        }
    }

    /// The JIT configs for every runner of the instance, in runner order.
    private func orderedJitConfigs(_ request: RegistrationRequest) throws -> [(name: String, config: String)] {
        let runnerNames = FleetEngine.runnerNames(for: request.name, count: request.runnerCount)
        guard runnerNames.allSatisfy({ request.runnerTokens[$0] != nil }),
            request.runnerTokens.count == runnerNames.count
        else {
            throw EngineError.registrationFailed(vm: request.name, stderr: "forge returned incomplete JIT configs")
        }
        return runnerNames.compactMap { runnerName in request.runnerTokens[runnerName].map { (runnerName, $0) } }
    }

    private func tartScript(_ request: RegistrationRequest) throws -> String {
        let forge = request.forge
        let runnerCount = request.runnerCount
        if case .jitConfig = forge.registration {
            let scripts = try orderedJitConfigs(request).enumerated().map { index, config in
                // Match the layout `kinhin image prepare` bakes: runner 1 lives in
                // ~/actions-runner; runners 2..N live in ~/actions-runner-2..N (the
                // classic script and the image-bake step agree on this). The previous
                // mapping used ~/actions-runner-(index+1), which produced a missing
                // ~/actions-runner-1 for the first multi-runner VM.
                let runnerNumber = index + 1
                let directory: String
                let workFolder: String
                if runnerCount == 1 {
                    directory = "~/actions-runner"
                    workFolder = "_work"
                } else {
                    directory =
                        runnerNumber == 1
                        ? "~/actions-runner"
                        : "~/actions-runner-\(runnerNumber)"
                    workFolder =
                        runnerNumber == 1
                        ? "_work"
                        : "_work-\(runnerNumber)"
                }
                return RunnerBootstrap.jitRegistrationScript(
                    encodedJitConfig: config.config,
                    name: config.name,
                    workFolder: workFolder,
                    agentDirectory: directory,
                    agentTemplate: runnerCount > 1 ? "~/actions-runner" : nil,
                    runnerVersion: RunnerVersionResolver.fallback.github
                )
            }.joined(separator: "\n")
            return scripts
        }
        return RunnerBootstrap.registrationScript(
            configureURL: forge.registrationURL(),
            token: request.token,
            labels: request.labels ?? forge.labels,
            ephemeral: request.route.ephemeral,
            name: request.name,
            runnerCount: runnerCount
        )
    }

    private func containerScript(_ request: RegistrationRequest) throws -> String {
        let forge = request.forge
        let name = request.name
        let runnerCount = request.runnerCount
        if case .jitConfig = forge.registration {
            let configs = try orderedJitConfigs(request)
            let scripts = configs.enumerated().map { index, config in
                // Match the layout `kinhin image prepare` bakes for Linux: runner 1
                // lives in /opt/actions-runner; runners 2..N live in
                // /opt/actions-runner-2..N. The previous mapping used
                // /opt/actions-runner-(index+1), which produced a missing
                // /opt/actions-runner-1 for the first multi-runner container.
                let runnerNumber = index + 1
                let directory: String
                let workFolder: String
                if runnerCount == 1 {
                    directory = "/opt/actions-runner"
                    workFolder = "/opt/work"
                } else {
                    directory =
                        runnerNumber == 1
                        ? "/opt/actions-runner"
                        : "/opt/actions-runner-\(runnerNumber)"
                    workFolder =
                        runnerNumber == 1
                        ? "/opt/work"
                        : "/opt/work-\(runnerNumber)"
                }
                return RunnerBootstrap.linuxJitRegistrationScript(
                    encodedJitConfig: config.config, name: config.name,
                    workFolder: workFolder, agentDirectory: directory,
                    pidFile: "/var/run/kinhin-\(name)-r\(runnerNumber).pid")
            }
            return scripts.joined(separator: "\n")
        }
        return RunnerBootstrap.linuxGitHubRegistrationScript(
            configureURL: forge.registrationURL(), token: request.token, labels: request.labels ?? forge.labels,
            ephemeral: request.route.ephemeral, name: name, runnerCount: runnerCount)
    }
}
