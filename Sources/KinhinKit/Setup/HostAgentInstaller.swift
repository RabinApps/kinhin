import Foundation

/// Installs the runner agents that `HostRuntime` runs directly on the Mac
/// (the fix behind `kinhin setup repair host-agent` and the checklist's
/// "Host runner agent" row): GitHub's actions-runner and the Gitea runner
/// (which also serves Forgejo), plus the GitLab runner, the Buildkite agent and
/// the Azure Pipelines agent when an account of that forge is configured, so a
/// host route works on every forge in use.
/// Downloads are SHA-256 verified against the vendors' published digests, the
/// same way `image prepare` verifies them. Agents already present are skipped.
public struct HostAgentInstaller: Sendable {
    let shell: ShellRunning
    let agentDir: URL
    let arm64: Bool
    let latestVersions: @Sendable () async -> RunnerVersionResolver.Versions
    /// Whether the GitLab agent is part of the install (and of `isInstalled`).
    public let includeGitLab: Bool
    /// Whether the Buildkite agent is part of the install (and of `isInstalled`).
    public let includeBuildkite: Bool
    /// Whether the Azure Pipelines agent is part of the install (and of `isInstalled`).
    public let includeAzureDevOps: Bool
    /// Whether the Bitbucket runner is part of the install (and of `isInstalled`).
    public let includeBitbucket: Bool

    public init(
        shell: ShellRunning = Shell(), agentDir: URL? = nil, arm64: Bool = ResourceProbe().snapshot().arm64,
        latestVersions: (@Sendable () async -> RunnerVersionResolver.Versions)? = nil,
        includeGitLab: Bool? = nil, includeBuildkite: Bool? = nil, includeAzureDevOps: Bool? = nil,
        includeBitbucket: Bool? = nil
    ) {
        self.shell = shell
        self.agentDir = agentDir ?? HostRuntime.defaultAgentDir
        self.arm64 = arm64
        self.latestVersions = latestVersions ?? { await RunnerVersionResolver().resolve() }
        let configured =
            (includeGitLab == nil || includeBuildkite == nil || includeAzureDevOps == nil || includeBitbucket == nil)
            ? Self.configuredForges() : []
        self.includeGitLab = includeGitLab ?? configured.contains(.gitlab)
        self.includeBuildkite = includeBuildkite ?? configured.contains(.buildkite)
        self.includeAzureDevOps = includeAzureDevOps ?? configured.contains(.azuredevops)
        self.includeBitbucket = includeBitbucket ?? configured.contains(.bitbucket)
    }

    /// The forges the on-disk config has accounts for.
    static func configuredForges() -> Set<ForgeID> {
        Set(AccountTokens.loadedConfig()?.accounts.map(\.forge) ?? [])
    }

    var githubAgentInstalled: Bool {
        FileManager.default.fileExists(atPath: agentDir.appendingPathComponent("config.sh").path)
    }

    var giteaAgentInstalled: Bool {
        FileManager.default.isExecutableFile(atPath: agentDir.appendingPathComponent("gitea-runner").path)
    }

    var gitlabAgentInstalled: Bool {
        FileManager.default.isExecutableFile(atPath: agentDir.appendingPathComponent("gitlab-runner").path)
    }

    var buildkiteAgentInstalled: Bool {
        FileManager.default.isExecutableFile(atPath: agentDir.appendingPathComponent("buildkite-agent").path)
    }

    var azureAgentInstalled: Bool {
        FileManager.default.isExecutableFile(atPath: agentDir.appendingPathComponent("azure-agent/config.sh").path)
    }

    var bitbucketRunnerInstalled: Bool {
        FileManager.default.isExecutableFile(atPath: agentDir.appendingPathComponent("bitbucket-runner/runner.sh").path)
    }

    /// True when every agent in use is present.
    public var isInstalled: Bool {
        githubAgentInstalled && giteaAgentInstalled && (!includeGitLab || gitlabAgentInstalled)
            && (!includeBuildkite || buildkiteAgentInstalled) && (!includeAzureDevOps || azureAgentInstalled)
            && (!includeBitbucket || bitbucketRunnerInstalled)
    }

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
        if includeGitLab, !gitlabAgentInstalled {
            parts.append(
                """
                \(RunnerBootstrap.gitlabRunnerDownloadScript(version: versions.gitlab, platform: arm64 ? "darwin-arm64" : "darwin-amd64", file: "gitlab-runner"))
                chmod +x gitlab-runner
                """)
        }
        if includeBuildkite, !buildkiteAgentInstalled {
            parts.append(
                """
                \(RunnerBootstrap.buildkiteAgentDownloadScript(version: versions.buildkite, platform: arm64 ? "darwin-arm64" : "darwin-amd64", file: "buildkite-agent.tar.gz"))
                tar xzf buildkite-agent.tar.gz ./buildkite-agent
                rm buildkite-agent.tar.gz
                """)
        }
        if includeAzureDevOps, !azureAgentInstalled {
            // The template each host runner clones (see HostRuntime+AzureDevOps).
            parts.append(
                """
                mkdir -p azure-agent
                (
                  cd azure-agent
                  \(RunnerBootstrap.azureAgentDownloadScript(version: versions.azure, platform: arm64 ? "osx-arm64" : "osx-x64", file: "agent.tar.gz").replacingOccurrences(of: "\n", with: "\n  "))
                  tar xzf agent.tar.gz
                  rm agent.tar.gz
                )
                """)
        }
        if includeBitbucket, !bitbucketRunnerInstalled {
            // The macOS runner (package + bundled JDK) each host runner uses.
            parts.append(
                RunnerBootstrap.bitbucketRunnerInstallScript(
                    version: versions.bitbucket, jdkVersion: versions.bitbucketJDK,
                    jdkPlatform: arm64 ? "aarch64_mac" : "x64_mac"
                )
                .replacingOccurrences(of: "$HOME", with: agentDir.path))
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
        if includeGitLab, !gitlabAgentInstalled {
            throw ImageError.hostAgentInstallFailed(
                "the download finished but gitlab-runner is missing in \(agentDir.path)")
        }
        if includeBuildkite, !buildkiteAgentInstalled {
            throw ImageError.hostAgentInstallFailed(
                "the download finished but buildkite-agent is missing in \(agentDir.path)")
        }
        if includeAzureDevOps, !azureAgentInstalled {
            throw ImageError.hostAgentInstallFailed(
                "the download finished but the Azure Pipelines agent is missing in \(agentDir.path)/azure-agent")
        }
        if includeBitbucket, !bitbucketRunnerInstalled {
            throw ImageError.hostAgentInstallFailed(
                "the download finished but the Bitbucket runner is missing in \(agentDir.path)/bitbucket-runner")
        }
        Log.info("host", "installed \(installedSummary(versions)) into \(agentDir.path)")
        return versions
    }

    /// "actions-runner 2.x, gitea-runner 3.x and buildkite-agent 4.x": the
    /// agents this installer covers, for log and CLI lines.
    public func installedSummary(_ versions: RunnerVersionResolver.Versions) -> String {
        var agents = ["actions-runner \(versions.github)", "gitea-runner \(versions.gitea)"]
        if includeGitLab { agents.append("gitlab-runner \(versions.gitlab)") }
        if includeBuildkite { agents.append("buildkite-agent \(versions.buildkite)") }
        if includeAzureDevOps { agents.append("azure pipelines agent \(versions.azure)") }
        if includeBitbucket { agents.append("bitbucket runner \(versions.bitbucket)") }
        guard let last = agents.popLast() else { return "" }
        return agents.joined(separator: ", ") + " and " + last
    }
}
