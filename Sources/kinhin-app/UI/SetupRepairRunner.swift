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

    /// Installs Apple's `container` CLI via Homebrew, then starts its
    /// system service. Skips the install when the CLI is already healthy.
    func installContainerCLI() {
        runWithProgress("Installing Apple container via Homebrew…") {
            let shell = Shell()
            if !(await AppleContainerRuntime(shell: shell).health()).isReady {
                try HostRequirements.ensureSupported(.appleContainer)
                let brew = Paths.findExecutable(named: "brew") ?? "/opt/homebrew/bin/brew"
                let result = try await shell.run([brew, "install", "container"], cwd: nil, timeout: 900)
                guard result.succeeded else {
                    throw NSError(
                        domain: "kinhin", code: 1,
                        userInfo: [
                            NSLocalizedDescriptionKey: result.stderr.isEmpty
                                ? "brew install container failed" : result.stderr
                        ])
                }
            }
            try await Self.startContainerSystem(shell: shell)
        }
    }

    /// Starts the container system service if it isn't running.
    func startContainerSystem() {
        runWithProgress("Starting the container system…") {
            try await Self.startContainerSystem(shell: Shell())
        }
    }

    /// Downloads the Linux kernel that containers boot with (one time).
    func installContainerKernel() {
        runWithProgress("Installing the Linux kernel for containers (one-time download)…") {
            try await AppleContainerRuntime.installKernel()
        }
    }

    /// Makes the container system usable: running, and with a Linux kernel
    /// installed (a system started by hand may lack one).
    static func startContainerSystem(shell: ShellRunning) async throws {
        try await startContainerServices(shell: shell)
        try await AppleContainerRuntime.ensureKernel(shell: shell)
    }

    private static func startContainerServices(shell: ShellRunning) async throws {
        guard !(await AppleContainerRuntime(shell: shell).health()).isReady else { return }
        let result = try await shell.run(
            // --enable-kernel-install: without it the CLI asks a question and
            // fails ("failed to read user input") when run without a terminal.
            [AppleContainerRuntime.resolvedBinaryPath, "system", "start", "--enable-kernel-install"],
            cwd: nil, timeout: 120
        )
        guard result.succeeded else {
            throw NSError(
                domain: "kinhin", code: 1,
                userInfo: [
                    NSLocalizedDescriptionKey: result.stderr.isEmpty ? "container system start failed" : result.stderr
                ])
        }
    }

    // MARK: Images

    /// Bakes the runner agents into the configured macOS runner image.
    func prepareImage() {
        runWithProgress("Preparing runner image (this takes a while)…") {
            let cfg = try ConfigLoader.load()
            let tart = try TartController(configuredPath: cfg.tartPath)
            let preparer = ImagePreparer(tart: tart, ssh: SSHExecutor())
            var options = ImagePreparer.Options()
            // The app's one-click prepare bakes the config's provision
            // script and managed toolchains too (same rule as the CLI's
            // `image prepare`).
            options.provisionScriptPath = cfg.provisionScript
            options.toolchains = cfg.toolchains
            try await preparer.run(options)
        }
    }

    /// Bakes the runner agents into the configured Linux container image.
    func prepareContainerImage() {
        runWithProgress("Preparing container image (this takes a while)…") {
            let cfg = try ConfigLoader.load()
            guard let image = cfg.container?.image else {
                throw ConfigError.invalid("no container.image is set — add a container: section first")
            }
            try await Self.startContainerSystem(shell: Shell())
            let preparer = ContainerImagePreparer(shell: Shell())
            // The config's toolchains section bakes into the Linux image too
            // (macOS-only entries are skipped for containers, never an error).
            let base = LinuxImageOptions.baseImage(
                configured: image, localImages: await AppleContainerRuntime().localImageNames(),
                fallback: LinuxBaseImage.resolve(configured: cfg.container?.baseImage))
            var options = ContainerImagePreparer.Options(image: base, target: image)
            options.toolchains = cfg.toolchains
            try await preparer.prepare(options)
        }
    }

    /// Bakes the runner agents into the configured Docker image.
    func prepareDockerImage() {
        runWithProgress("Preparing docker image (this takes a while)…") {
            let cfg = try ConfigLoader.load()
            guard let image = cfg.docker?.image else {
                throw ConfigError.invalid("no docker.image is set — add a docker: section first")
            }
            let preparer = DockerImagePreparer(shell: Shell())
            // The config's toolchains section bakes into the Linux image too
            // (macOS-only entries are skipped for containers, never an error).
            let base = LinuxImageOptions.baseImage(
                configured: image,
                localImages: await DockerRuntime(image: image).localImageNames(
                    reusing: image, for: cfg.docker?.platform ?? .arm64),
                fallback: LinuxBaseImage.resolve(configured: cfg.docker?.baseImage))
            var options = DockerImagePreparer.Options(image: base, target: image)
            options.platform = cfg.docker?.platform ?? .arm64
            options.toolchains = cfg.toolchains
            try await preparer.prepare(options)
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
