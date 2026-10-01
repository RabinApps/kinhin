import Foundation
import KinhinKit

enum ImageCommand {
    /// The interactive menu over `TartBaseImage`'s pre-configured Linux
    /// images (bare `--from`). Returns the picked reference.
    static func pickCuratedLinuxImage() throws -> String {
        let linux = TartBaseImage.curatedLinux
        print("Pre-configured tart images (all use admin/admin and Tart's SSH key):")
        for (index, entry) in linux.enumerated() {
            print("  \(index + 1). \(entry.title) — \(entry.reference)")
        }
        print("Choice [1-\(linux.count)]: ", terminator: "")
        guard let line = readLine()?.trimmingCharacters(in: .whitespaces), let pick = Int(line),
            linux.indices.contains(pick - 1)
        else {
            fail("pick a number between 1 and \(linux.count)", exit: .usage)
        }
        return linux[pick - 1].reference
    }

    /// `kinhin image digest <reference>` — resolve the digest the registry
    /// currently serves, so `base_image:` can be pinned to the reproducible
    /// `ref@sha256:…` form. Public commands only; no config needed.
    static func runDigest(_ args: [String]) async throws {
        guard let reference = flag("--ref", in: args) ?? args.first, !reference.isEmpty else {
            fail("image digest needs a reference: kinhin image digest <registry>/<repo>:<tag>", exit: .usage)
        }
        if let problem = TartBaseImage.problem(with: reference) {
            fail("'\(reference)' is not a usable image reference: \(problem)", exit: .usage)
        }
        if TartBaseImage.isDigestPinned(reference) {
            fail(
                "'\(reference)' is already digest-pinned — there is nothing to resolve",
                exit: .usage)
        }
        do {
            let digest = try await RegistryDigestResolver().resolveDigest(reference)
            print("\(reference)@\(digest)")
            print("pin it: base_image: \"\(reference)@\(digest)\"")
        } catch let error as ImageError {
            guard case .malformedVersionFeed(_, let reason) = error else { fail(error) }
            fail("could not resolve a digest for \(reference): \(reason)", exit: .runtime)
        } catch {
            fail(error)
        }
    }

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
            if hasFlag("--iso", in: args), hasFlag("--from", in: args) {
                fail(
                    "--iso and --from are mutually exclusive: pick a pre-configured image or an install ISO",
                    exit: .usage)
            }
            do {
                let tart = try TartController(configuredPath: cfg.tartPath)
                let creator = TartLinuxVMCreator(tart: tart)
                let iso = flag("--iso", in: args)
                if hasFlag("--from", in: args) {
                    // `--from` bare = the curated pre-configured menu;
                    // `--from <ref>` = any tart image reference.
                    let from: String
                    if let reference = flag("--from", in: args) {
                        from = reference
                    } else {
                        from = try Self.pickCuratedLinuxImage()
                    }
                    try await creator.run(TartLinuxVMCreator.Options(name: name, from: from))
                    print("Pre-configured image ready: \(name)")
                    print("Bake the runner agents into it with:")
                    print("  kinhin image prepare --source \(name)")
                    return
                }
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
                    "tart is not installed. Install it first (or click 'Install via Homebrew' in the app): \(TartHealthProbe.installCommand)",
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
            var options = ImagePreparer.Options(config: cfg)
            options.source = flag("--source", in: args) ?? options.source
            options.target = flag("--target", in: args) ?? options.target
            options.runnerVersion = flag("--runner-version", in: args) ?? options.runnerVersion
            // The flag wins over the config key; either may be absent (no
            // user script is baked in that case).
            options.provisionScriptPath = flag("--provision-script", in: args) ?? options.provisionScriptPath
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
            }
            try await preparer.run(options)
            print("image ready: \(options.target)")
            print("set `image: \"\(options.target)\"` in your config to use it")
        } catch TartError.missingBinary {
            fail(
                "tart is not installed. Install it first (or click 'Install via Homebrew' in the app): \(TartHealthProbe.installCommand)",
                exit: .runtime)
        } catch {
            fail(error)
        }
    }
}
