import Foundation
import OrchardKit

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
                let target = flag("--target", in: args) ?? "orchard-ci-linux"
                let preparer = ContainerImagePreparer(shell: shell)
                let baked = try await preparer.prepare(image: image, target: target)
                print("container image ready: \(baked)")
                print("set `container.image: \"\(baked)\"` in your config to use it")
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
