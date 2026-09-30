import Foundation
import KinhinKit

/// The setup repair and install actions, free of UI: install or roll back
/// tart, prepare the runner images, bring up the container system, install
/// the host runner agents, and create the toolchain cache. Every long task
/// runs behind `runWithProgress` (a small progress window in the app, headless
/// in tests), and failures surface through `AlertKit`.
///
/// The checklist window that used to host these is gone (the Setup tab shows
/// the SwiftUI wizard), but the logic is shared: the wizard's This-Mac form
/// and the Toolchains rebuilds call the same `startContainerSystem` and image
/// preparers, and `kinhin setup repair host-agent` walks the same installer.
@MainActor
final class SetupRepairRunner {
    /// Presents progress while a long task runs; injectable so tests run
    /// repairs headless.
    var runWithProgress: (_ title: String, _ body: @escaping () async throws -> Void) -> Void = { title, body in
        RepairProgress.run(title: title, body)
    }

    // MARK: Tart

    func installTart() {
        runRepair(TartHealthProbe.repairs(for: .missing)[0], progressTitle: "Installing tart via Homebrew…")
    }

    func rollbackTart() {
        runRepair(
            TartHealthProbe.repairs(for: .killedOnLaunch)[0],
            progressTitle: "Rolling back to the notarized Cirrus Labs tart…")
    }

    /// Runs a repair plan's commands, then verifies tart actually launches.
    func runRepair(_ repair: TartRepair, progressTitle: String) {
        runWithProgress(progressTitle) {
            let shell = Shell()
            // Check-then-repair: skip Homebrew entirely when tart already launches.
            guard await TartHealthProbe(shell: shell).check() != .healthy else { return }
            try await Self.run(repair, shell: shell)
            // A "successful" install can still be a Gatekeeper kill — verify.
            let health = await TartHealthProbe(shell: shell).check()
            if health != .healthy {
                let plan = TartHealthProbe.repairs(for: health).first
                let hint = plan.map { " Follow up with: \($0.commandLine)" } ?? ""
                throw NSError(
                    domain: "kinhin", code: 1,
                    userInfo: [NSLocalizedDescriptionKey: "tart did not launch after the operation.\(hint)"])
            }
        }
    }

    static func run(_ repair: TartRepair, shell: ShellRunning) async throws {
        for command in repair.commands {
            let result = try await shell.run(command, cwd: nil, timeout: 900)
            guard result.succeeded else {
                let what = command.joined(separator: " ")
                throw NSError(
                    domain: "kinhin", code: 1,
                    userInfo: [
                        NSLocalizedDescriptionKey: result.stderr.isEmpty ? "brew failed: \(what)" : result.stderr
                    ])
            }
        }
    }

    // MARK: Container system

    /// Starts the container system service if it isn't running.
    func startContainerSystem() {
        runWithProgress("Starting the container system…") {
            try await AppleContainerRuntime.startSystem()
        }
    }

    /// Downloads the Linux kernel that containers boot with (one time).
    func installContainerKernel() {
        runWithProgress("Installing the Linux kernel for containers (one-time download)…") {
            try await AppleContainerRuntime.installKernel()
        }
    }

    // MARK: Images

    /// Bakes the runner agents into the configured macOS runner image.
    func prepareImage() {
        runWithProgress("Preparing runner image (this takes a while)…") {
            try await ImageBuildService.rebuild(.tart, config: ConfigLoader.load())
        }
    }

    /// Bakes the runner agents into the configured Linux container image.
    func prepareContainerImage() {
        runWithProgress("Preparing container image (this takes a while)…") {
            try await ImageBuildService.rebuild(.appleContainer, config: ConfigLoader.load())
        }
    }

    /// Bakes the runner agents into the configured Docker image.
    func prepareDockerImage() {
        runWithProgress("Preparing docker image (this takes a while)…") {
            try await ImageBuildService.rebuild(.docker, config: ConfigLoader.load())
        }
    }

    // MARK: Host support

    /// Downloads the GitHub and Gitea runner agents that host-mode routes
    /// run on this Mac.
    func installHostAgent() {
        runWithProgress("Installing the host runner agents…") {
            try await HostAgentInstaller().install()
        }
    }

    /// Creates the host toolchain-cache directory so `share_cache` mounts
    /// land on a real path. Pure mkdir — safe to run anytime.
    func createToolchainCache() {
        runWithProgress("Creating the shared toolchain cache…") {
            do {
                try FileManager.default.createDirectory(at: Paths.toolchainCache, withIntermediateDirectories: true)
                Log.info("setup", "toolchain cache created at \(Paths.toolchainCache.path)")
            } catch {
                Log.error("setup", "could not create toolchain cache: \(error.localizedDescription)")
                throw error
            }
        }
    }
}
