import Foundation

/// Installs the runner agents that `HostRuntime` runs directly on the Mac
/// (the fix behind `kinhin setup repair host-agent` and the checklist's
/// "Host runner agent" row): GitHub's actions-runner and the Gitea runner
/// (which also serves Forgejo), so a host route works on every forge.
/// Downloads are SHA-256 verified against the vendors' published digests, the
/// same way `image prepare` verifies them. Agents already present are skipped.
public struct HostAgentInstaller: Sendable {
    let shell: ShellRunning
    let agentDir: URL
    let arm64: Bool
    let latestVersions: @Sendable () async -> RunnerVersionResolver.Versions

    public init(
        shell: ShellRunning = Shell(), agentDir: URL? = nil, arm64: Bool = ResourceProbe().snapshot().arm64,
        latestVersions: (@Sendable () async -> RunnerVersionResolver.Versions)? = nil
    ) {
        self.shell = shell
        self.agentDir = agentDir ?? HostRuntime.defaultAgentDir
        self.arm64 = arm64
        self.latestVersions = latestVersions ?? { await RunnerVersionResolver().resolve() }
    }

    var githubAgentInstalled: Bool {
        FileManager.default.fileExists(atPath: agentDir.appendingPathComponent("config.sh").path)
    }

    var giteaAgentInstalled: Bool {
        FileManager.default.isExecutableFile(atPath: agentDir.appendingPathComponent("gitea-runner").path)
    }

    /// True when both agents are present.
    public var isInstalled: Bool { githubAgentInstalled && giteaAgentInstalled }

    /// The install script for whichever agents are missing.
    func installScript(_ versions: RunnerVersionResolver.Versions) -> String {
        var parts = ["set -euo pipefail"]
        if !githubAgentInstalled {
            parts.append(
                """
                \(RunnerBootstrap.githubRunnerDownloadScript(version: versions.github, platform: arm64 ? "osx-arm64" : "osx-x64", file: "runner.tar.gz"))
                tar xzf runner.tar.gz
                rm runner.tar.gz
                """)
        }
        if !giteaAgentInstalled {
            parts.append(
                """
                \(RunnerBootstrap.giteaRunnerDownloadScript(version: versions.gitea, platform: arm64 ? "darwin-arm64" : "darwin-amd64", file: "runner.xz"))
                xz -d runner.xz
                chmod +x runner
                mv runner gitea-runner
                """)
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
        guard githubAgentInstalled else {
            throw ImageError.hostAgentInstallFailed(
                "the download finished but config.sh is missing in \(agentDir.path)")
        }
        guard giteaAgentInstalled else {
            throw ImageError.hostAgentInstallFailed(
                "the download finished but gitea-runner is missing in \(agentDir.path)")
        }
        Log.info(
            "host",
            "installed actions-runner \(versions.github) and gitea-runner \(versions.gitea) into \(agentDir.path)")
        return versions
    }
}
