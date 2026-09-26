import Foundation

/// Installs the GitHub actions-runner agent that `HostRuntime` runs directly
/// on the Mac (the fix behind `kinhin setup repair host-agent` and the
/// checklist's "Host runner agent" row). Downloads the release matching this
/// machine's architecture into `agentDir`; a no-op when `config.sh` exists.
public struct HostAgentInstaller: Sendable {
    let shell: ShellRunning
    let agentDir: URL
    let arm64: Bool
    let latestVersion: @Sendable () async -> String

    public init(
        shell: ShellRunning = Shell(), agentDir: URL? = nil, arm64: Bool = ResourceProbe().snapshot().arm64,
        latestVersion: (@Sendable () async -> String)? = nil
    ) {
        self.shell = shell
        self.agentDir = agentDir ?? HostRuntime.defaultAgentDir
        self.arm64 = arm64
        self.latestVersion =
            latestVersion ?? { await RunnerVersionResolver().latestGitHub() ?? RunnerVersionResolver.fallback.github }
    }

    public var isInstalled: Bool {
        FileManager.default.fileExists(atPath: agentDir.appendingPathComponent("config.sh").path)
    }

    /// The download URL for `version` on this architecture.
    func downloadURL(version: String) -> String {
        let arch = arm64 ? "arm64" : "x64"
        return
            "https://github.com/actions/runner/releases/download/v\(version)/actions-runner-osx-\(arch)-\(version).tar.gz"
    }

    /// Downloads and unpacks the agent. Returns the installed version.
    @discardableResult
    public func install() async throws -> String {
        let version = await latestVersion()
        try FileManager.default.createDirectory(at: agentDir, withIntermediateDirectories: true)
        let script =
            "set -euo pipefail; curl -fsSL \(RunnerBootstrap.shellQuote(downloadURL(version: version))) | tar xz"
        let result = try await shell.run(["/bin/bash", "-c", script], cwd: agentDir, timeout: 600)
        guard result.succeeded else {
            throw ImageError.hostAgentInstallFailed(result.failureExcerpt)
        }
        guard isInstalled else {
            throw ImageError.hostAgentInstallFailed(
                "the download finished but config.sh is missing in \(agentDir.path)")
        }
        Log.info("host", "installed actions-runner \(version) into \(agentDir.path)")
        return version
    }
}
