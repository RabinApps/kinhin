import Foundation

/// Installs the runner agents that `HostRuntime` runs directly on the Mac
/// (the fix behind `kinhin setup repair host-agent` and the checklist's
/// "Host runner agent" row): GitHub's actions-runner and the Gitea runner
/// (which also serves Forgejo), plus the agent of every other forge that has
/// an account configured, so a host route works on every forge in use.
/// Downloads are SHA-256 verified against the vendors' published digests, the
/// same way `image prepare` verifies them. Agents already present are skipped.
///
/// The agents themselves are described by each forge's `RunnerAgentSpec`
/// (`host`): this type only iterates them.
public struct HostAgentInstaller: Sendable {
    let shell: ShellRunning
    let agentDir: URL
    let arm64: Bool
    let latestVersions: @Sendable () async -> RunnerVersionResolver.Versions
    /// The forges whose agent is part of the install (and of `isInstalled`)
    /// beyond the always-installed ones (GitHub and Gitea).
    let includedForges: Set<ForgeID>

    /// - Parameter including: the forges that have an account (nil = read the
    ///   on-disk config). Agents that are always installed need no entry.
    public init(
        shell: ShellRunning = Shell(), agentDir: URL? = nil, arm64: Bool = ResourceProbe().snapshot().arm64,
        latestVersions: (@Sendable () async -> RunnerVersionResolver.Versions)? = nil,
        including forges: Set<ForgeID>? = nil
    ) {
        self.shell = shell
        self.agentDir = agentDir ?? HostRuntime.defaultAgentDir
        self.arm64 = arm64
        self.latestVersions = latestVersions ?? { await RunnerVersionResolver().resolve() }
        self.includedForges = forges ?? Self.configuredForges()
    }

    /// The forges the on-disk config has accounts for.
    static func configuredForges() -> Set<ForgeID> {
        Set(AccountTokens.loadedConfig()?.accounts.map(\.forge) ?? [])
    }

    /// The agents this installer covers, in install order.
    private var agents: [RunnerAgentSpec] {
        RunnerAgentSpec.all.filter { $0.host.required || $0.forges.contains(where: includedForges.contains) }
    }

    /// True when every agent in use is present.
    public var isInstalled: Bool {
        agents.allSatisfy { $0.host.isInstalled(in: agentDir) }
    }

    /// The install script for whichever agents are missing.
    func installScript(_ versions: RunnerVersionResolver.Versions) -> String {
        var parts = ["set -euo pipefail"]
        for agent in agents where !agent.host.isInstalled(in: agentDir) {
            parts.append(agent.host.installScript(versions, arm64, agentDir))
        }
        return parts.joined(separator: "\n")
    }

    /// Downloads and unpacks the missing agents. Returns the versions used.
    @discardableResult
    public func install() async throws -> RunnerVersionResolver.Versions {
        let versions = await latestVersions()
        try FileManager.default.createDirectory(at: agentDir, withIntermediateDirectories: true)
        let result = try await shell.run(["/bin/bash", "-c", installScript(versions)], cwd: agentDir, timeout: 900)
        guard result.succeeded else {
            throw ImageError.hostAgentInstallFailed(result.failureExcerpt)
        }
        for agent in agents where !agent.host.isInstalled(in: agentDir) {
            throw ImageError.hostAgentInstallFailed(agent.host.missingMessage(in: agentDir))
        }
        Log.info("host", "installed \(installedSummary(versions)) into \(agentDir.path)")
        return versions
    }

    /// "actions-runner 2.x, gitea-runner 3.x and buildkite-agent 4.x": the
    /// agents this installer covers, for log and CLI lines.
    public func installedSummary(_ versions: RunnerVersionResolver.Versions) -> String {
        var names = agents.map { "\($0.host.summaryName) \($0.version(versions))" }
        guard let last = names.popLast() else { return "" }
        return names.joined(separator: ", ") + " and " + last
    }
}
