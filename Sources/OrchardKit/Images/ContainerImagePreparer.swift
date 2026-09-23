import Foundation

/// Bakes the runner agents into a Linux OCI image for the Apple-container
/// runtime: boots a scratch container from the base image, installs the
/// GitHub Actions agent and/or gitea-runner (token-gated, mirroring the VM
/// prepare path), commits via `container build`, tags the result, and cleans
/// up the scratch container.
public struct ContainerImagePreparer {
    let shell: ShellRunning

    public init(shell: ShellRunning) {
        self.shell = shell
    }

    /// Resolve the runner-agent versions from the vendors' feeds (pinned
    /// fallback offline), then run the bake.
    @discardableResult
    public func prepare(image: String, target: String, user: String = "admin") async throws -> String {
        let versions = await RunnerVersionResolver().resolve()
        return try await prepare(image: image, target: target, versions: versions, user: user)
    }

    /// Testable core with injected versions.
    public func prepare(image: String, target: String, versions: RunnerVersionResolver.Versions, user: String) async throws -> String {
        // Token-gated provisioning: identical policy to the VM path.
        let hasGitHubToken = KeychainTokenStore.load(forge: .github) != nil
        let hasGiteaToken = KeychainTokenStore.load(forge: .gitea) != nil
        guard hasGitHubToken || hasGiteaToken else {
            throw ContainerImageError.noCredentials("store at least one platform token first (orchard auth set / orchard auth set --gitea)")
        }

        var lines: [String] = []
        if hasGitHubToken {
            Log.info("container-image", "GitHub PAT found — baking actions-runner \(versions.github)")
            lines.append(RunnerBootstrap.linuxGitHubAgentInstallScript(runnerVersion: versions.github))
        } else {
            Log.info("container-image", "no GitHub PAT stored — skipping actions-runner install")
        }
        if hasGiteaToken {
            Log.info("container-image", "Gitea token found — baking gitea-runner \(versions.gitea)")
            lines.append(RunnerBootstrap.linuxGiteaRunnerInstallScript(version: versions.gitea))
        } else {
            Log.info("container-image", "no Gitea token stored — skipping gitea-runner install")
        }
        let script = lines.joined(separator: "\n\n")

        let containerBin = Paths.findExecutable(named: "container") ?? "/usr/local/bin/container"

        // 1. Boot a scratch container from the base image.
        let scratch = "orchard-prepare-tmp-\(Int(Date().timeIntervalSince1970))"
        Log.info("container-image", "starting scratch container from \(image)")
        _ = try await shell.run([containerBin, "run", "--detach", "--name", scratch, image,
                                 "/bin/bash", "-lc", "while true; do sleep 3600; done"])

        do {
            // 2. Wait until it answers exec (the microVM takes a few seconds).
            try await waitUntilReady(scratch, containerBin: containerBin)

            // 3. Inject the agents.
            Log.info("container-image", "installing runner agents")
            let exec = try await shell.run([containerBin, "exec", scratch, "/bin/bash", "-lc", script])
            guard exec.succeeded else {
                throw ContainerImageError.provisioningFailed(String(exec.stderr.prefix(500)))
            }

            // 4. Commit the filesystem to the target tag.
            Log.info("container-image", "building target image \(target)")
            let workdir = FileManager.default.temporaryDirectory
                .appendingPathComponent("orchard-container-build-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: workdir, withIntermediateDirectories: true)
            let dockerfile = workdir.appendingPathComponent("Dockerfile")
            try "FROM \(scratch)\n".write(to: dockerfile, atomically: true, encoding: .utf8)
            let build = try await shell.run([containerBin, "build", "--tag", target, workdir.path])
            guard build.succeeded else {
                throw ContainerImageError.provisioningFailed("container build failed: \(String(build.stderr.prefix(500)))")
            }
        } catch {
            try? await shell.run([containerBin, "delete", "--force", scratch])
            throw error
        }

        // 5. Clean up the scratch container.
        _ = try? await shell.run([containerBin, "delete", "--force", scratch])
        Log.info("container-image", "prepared container image '\(target)' is ready")
        return target
    }

    /// Polls `container exec true` until the scratch container accepts exec.
    func waitUntilReady(_ id: String, containerBin: String, timeout: TimeInterval = 120, pollInterval: TimeInterval = 2) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            let probe = try await shell.run([containerBin, "exec", id, "/bin/true"])
            if probe.succeeded { return }
            try? await Task.sleep(nanoseconds: UInt64(pollInterval * 1_000_000_000))
        }
        throw ContainerImageError.provisioningFailed("scratch container never became ready for exec within \(Int(timeout))s")
    }
}

public enum ContainerImageError: LocalizedError {
    case provisioningFailed(String)
    case noCredentials(String)

    public var errorDescription: String? {
        switch self {
        case .provisioningFailed(let why): return "container image provisioning failed: \(why)"
        case .noCredentials(let why): return "no platform credentials: \(why)"
        }
    }
}
