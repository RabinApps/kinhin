import Foundation
import KinhinKit

enum ImageCommand {
    static func run(_ args: [String]) async throws {
        let cfg = loadConfigOrExit()
        if hasFlag("--linux", in: args) {
            // Linux tart VM from scratch (the tart.run quick-start flow):
            // create the bare VM, optionally attach install media for the
            // one-time interactive OS install, and point at
            // `image prepare --source <vm>` for the agent bake.
            if hasFlag("--container", in: args) || hasFlag("--docker", in: args) {
                fail("--linux cannot be combined with --container or --docker", exit: .usage)
            }
            guard let name = flag("--target", in: args), !name.isEmpty else {
                fail("--linux needs --target <vm-name>: the name of the base VM you are creating", exit: .usage)
            }
            do {
                let tart = try TartController(configuredPath: cfg.tartPath)
                let creator = TartLinuxVMCreator(tart: tart)
                let iso = flag("--iso", in: args)
                try await creator.run(TartLinuxVMCreator.Options(name: name, isoPath: iso))
                if iso != nil {
                    print("Linux VM '\(name)' created and booting with install media.")
                    print(
                        "Finish the OS install in the VM window (create an 'admin' user with your SSH key), then bake the runner agents with:"
                    )
                    print("  kinhin image prepare --source \(name)")
                } else {
                    print(
                        "Linux VM '\(name)' created (no OS yet — re-run with --iso <arm64.iso> to attach install media)."
                    )
                }
            } catch TartError.missingBinary {
                fail(
                    "tart is not installed. Install it first (or click 'Install via Homebrew' in the app): brew tap openai/tools && brew trust openai/tools && brew install openai/tools/tart",
                    exit: .runtime)
            } catch {
                fail(error)
            }
            return
        }
        if hasFlag("--container", in: args) {
            // Apple-container runtime path: bake agents into a Linux OCI image
            // (no tart involved). Refuses when no platform token is stored,
            // mirroring the VM path's token-gating.
            let shell = Shell()
            guard let containerBin = Paths.findExecutable(named: "container") else {
                fail(
                    "the container CLI is not installed. Install it first: brew install container && container system start",
                    exit: .runtime)
            }
            do {
                let status = try await shell.run([containerBin, "system", "status"])
                guard status.succeeded else {
                    fail(
                        "the container system service is not running. Start it first: container system start",
                        exit: .runtime)
                }
                let image = LinuxBaseImage.resolve(
                    configured: cfg.container?.baseImage, flagOverride: flag("--container-image", in: args))
                let target = flag("--target", in: args) ?? "kinhin-ci-linux"
                let preparer = ContainerImagePreparer(shell: shell)
                var options = ContainerImagePreparer.Options(image: image, target: target)
                // Managed toolchains for the Linux bake: config section by
                // default; --linux-toolchain / --linux-stack flags
                // (repeatable) override it for this prepare. A bare flag
                // means "no managed toolchains". macOS-only entries are
                // skipped with a note, never an error.
                let specFlags = allFlags("--linux-toolchain", in: args)
                let stackFlags = allFlags("--linux-stack", in: args)
                if !specFlags.isEmpty || !stackFlags.isEmpty {
                    let override = PartialConfig.PartialToolchains(
                        specs: specFlags.isEmpty ? nil : specFlags,
                        stacks: stackFlags.isEmpty ? nil : stackFlags
                    )
                    options.toolchains = try ConfigLoader.parseToolchains(override)
                } else {
                    options.toolchains = cfg.toolchains
                }
                let baked = try await preparer.prepare(options)
                print("container image ready: \(baked)")
                print("set `container.image: \"\(baked)\"` in your config to use it")
            } catch {
                fail(error)
            }
            return
        }
        if hasFlag("--docker", in: args) {
            // Docker runtime path: bake agents into a Linux OCI image via the
            // docker CLI (Docker Desktop / OrbStack / colima). Same
            // token-gating as the other prepare paths.
            let shell = Shell()
            let dockerHealth = await DockerRuntime(shell: shell, image: "probe").health()
            switch dockerHealth {
            case .missing(_, let howToFix):
                fail("docker is not available. \(howToFix)", exit: .runtime)
            case .broken(let why):
                fail(why, exit: .runtime)
            case .ready:
                break
            }
            let image = LinuxBaseImage.resolve(
                configured: cfg.docker?.baseImage, flagOverride: flag("--docker-image", in: args))
            let target = flag("--target", in: args) ?? "kinhin-ci-linux"
            do {
                let preparer = DockerImagePreparer(shell: shell)
                var options = DockerImagePreparer.Options(image: image, target: target)
                // --platform overrides docker.platform for this bake; amd64
                // runs under emulation, so say so before the long work starts.
                if let raw = flag("--platform", in: args) {
                    guard let parsed = LinuxPlatform(configValue: raw) else {
                        fail("--platform must be linux/arm64 or linux/amd64, got \"\(raw)\"", exit: .usage)
                    }
                    options.platform = parsed
                } else {
                    options.platform = cfg.docker?.platform ?? .arm64
                }
                if options.platform.isEmulated {
                    warn(LinuxPlatform.emulationNotice)
                }
                // Managed toolchains for the Linux bake: config section by
                // default; --linux-toolchain / --linux-stack flags
                // (repeatable) override it for this prepare. A bare flag
                // means "no managed toolchains". macOS-only entries are
                // skipped with a note, never an error.
                let specFlags = allFlags("--linux-toolchain", in: args)
                let stackFlags = allFlags("--linux-stack", in: args)
                if !specFlags.isEmpty || !stackFlags.isEmpty {
                    let override = PartialConfig.PartialToolchains(
                        specs: specFlags.isEmpty ? nil : specFlags,
                        stacks: stackFlags.isEmpty ? nil : stackFlags
                    )
                    options.toolchains = try ConfigLoader.parseToolchains(override)
                } else {
                    options.toolchains = cfg.toolchains
                }
                let baked = try await preparer.prepare(options)
                print("docker image ready: \(baked)")
                print("set `docker.image: \"\(baked)\"` in your config to use it")
            } catch {
                fail(error)
            }
            return
        }
        do {
            let tart = try TartController(configuredPath: cfg.tartPath)
            let preparer = ImagePreparer(tart: tart, ssh: SSHExecutor())
            var options = ImagePreparer.Options()
            options.source = flag("--source", in: args) ?? options.source
            options.target = flag("--target", in: args) ?? options.target
            options.runnerVersion = flag("--runner-version", in: args) ?? options.runnerVersion
            // The flag wins over the config key; either may be absent (no
            // user script is baked in that case).
            options.provisionScriptPath = flag("--provision-script", in: args) ?? cfg.provisionScript
            // Managed toolchains: config section by default; --toolchain /
            // --stack flags (repeatable) override it for this prepare. A
            // bare --toolchain/--stack means "no managed toolchains".
            let specFlags = allFlags("--toolchain", in: args)
            let stackFlags = allFlags("--stack", in: args)
            if !specFlags.isEmpty || !stackFlags.isEmpty {
                let override = PartialConfig.PartialToolchains(
                    specs: specFlags.isEmpty ? nil : specFlags,
                    stacks: stackFlags.isEmpty ? nil : stackFlags
                )
                options.toolchains = try ConfigLoader.parseToolchains(override)
            } else {
                options.toolchains = cfg.toolchains
            }
            try await preparer.run(options)
            print("image ready: \(options.target)")
            print("set `image: \"\(options.target)\"` in your config to use it")
        } catch TartError.missingBinary {
            fail(
                "tart is not installed. Install it first (or click 'Install via Homebrew' in the app): brew tap openai/tools && brew trust openai/tools && brew install openai/tools/tart",
                exit: .runtime)
        } catch {
            fail(error)
        }
    }
}
