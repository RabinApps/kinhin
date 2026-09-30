import Foundation

// MARK: - Azure DevOps on the host

extension HostRuntime {
    /// The Azure Pipelines agent installed by `HostAgentInstaller`; each
    /// runner gets an APFS clone of it.
    var azureAgentTemplate: URL { agentDir.appendingPathComponent("azure-agent", isDirectory: true) }

    /// Azure registration on the Mac itself: each agent's copy, token file,
    /// work dir, log and pid live in `<instance work dir>/<runner name>`, so
    /// teardown's scrub removes them with the instance.
    func azureRegistrationScript(forge: Forge, token: String, name: String, runnerCount: Int) -> String {
        RunnerBootstrap.azureRegistrationScript(
            organization: forge.registrationURL(), token: token, pool: forge.scope,
            runnerNames: FleetEngine.runnerNames(for: name, count: runnerCount),
            capabilities: AzureDevOpsForge.capabilityEnvironment(forge.labels),
            template: RunnerBootstrap.shellQuote(azureAgentTemplate.path),
            baseDir: RunnerBootstrap.shellQuote(workDirectory(for: name).path), copy: .apfsClone)
    }

    /// Stops this instance's Azure agents that have not finished their job (a
    /// scale-down or engine stop mid-job).
    func stopAzureAgents(id: String) async {
        await stopRecordedAgents(id: id, pidFile: "agent.pid", command: "run.sh --once", what: "azure agents")
    }
}
