import Foundation
import KinhinKit

enum ImageCommand {
    static func run(_ args: [String]) async throws {
        let cfg = loadConfigOrExit()
        if hasFlag("--container", in: args) {
            // Apple-container runtime path: bake agents into a Linux OCI image
            // (no tart involved). Refuses when no platform token is stored,
            // mirroring the VM path's token-gating.
            let shell = Shell()
            guard let containerBin = Paths.findExecutable(named: "container") else {
                fail("the container CLI is not installed. Install it first: brew install --cask container && container system start")
            }
            do {
                let status = try await shell.run([containerBin, "system", "status"])
                guard status.succeeded else {
                    fail("the container system service is not running. Start it first: container system start")
                }
                let image = flag("--container-image", in: args) ?? "ubuntu:24.04"
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
            } catch let error as ContainerImageError {
                fail(error.localizedDescription)
            } catch {
                fail(error.localizedDescription)
            }
            exit(0)
        }
        if hasFlag("--docker", in: args) {
            // Docker runtime path: bake agents into a Linux OCI image via the
            // docker CLI (Docker Desktop / OrbStack / colima). Same
            // token-gating as the other prepare paths.
            let shell = Shell()
            let dockerHealth = await DockerRuntime(shell: shell, image: "probe").health()
            switch dockerHealth {
            case .missing(_, let howToFix):
                fail("docker is not available. \(howToFix)")
            case .broken(let why):
                fail(why)
            case .ready:
                break
            }
            let image = flag("--docker-image", in: args) ?? "ubuntu:24.04"
            let target = flag("--target", in: args) ?? "kinhin-ci-linux"
            do {
                let preparer = DockerImagePreparer(shell: shell)
                var options = DockerImagePreparer.Options(image: image, target: target)
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
            } catch let error as ContainerImageError {
                fail(error.localizedDescription)
            } catch {
                fail(error.localizedDescription)
            }
            exit(0)
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
            fail("tart is not installed. Install it first (or click 'Install via Homebrew' in the app): brew tap openai/tools && brew trust openai/tools && brew install openai/tools/tart")
        } catch {
            fail(error.localizedDescription)
        }
    }
}
