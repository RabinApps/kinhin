import Foundation

/// Bakes the runner agents into a Linux OCI image for the Docker runtime:
/// boots a scratch container from the base image (`docker run`), installs the
/// GitHub Actions agent and/or gitea-runner (token-gated, mirroring the VM
/// and Apple-container prepare paths), commits via `docker commit`, tags the
/// result, and cleans up the scratch container.
///
/// Unlike the Apple-container preparer (which must `container build` because
/// `container` has no commit), Docker's native `commit` keeps this a simple
/// three-command bake with no temp build context.
public struct DockerImagePreparer {
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
        // Token-gated provisioning: identical policy to the other paths.
        let hasGitHubToken = KeychainTokenStore.load(forge: .github) != nil
        let hasGiteaToken = KeychainTokenStore.load(forge: .gitea) != nil
        guard hasGitHubToken || hasGiteaToken else {
            throw ContainerImageError.noCredentials("store at least one platform token first (orchard auth set / orchard auth set --gitea)")
        }

        var lines: [String] = []
        if hasGitHubToken {
            Log.info("docker-image", "GitHub PAT found — baking actions-runner \(versions.github)")
            lines.append(RunnerBootstrap.linuxGitHubAgentInstallScript(runnerVersion: versions.github))
        } else {
            Log.info("docker-image", "no GitHub PAT stored — skipping actions-runner install")
        }
        if hasGiteaToken {
            Log.info("docker-image", "Gitea token found — baking gitea-runner \(versions.gitea)")
            lines.append(RunnerBootstrap.linuxGiteaRunnerInstallScript(version: versions.gitea))
        } else {
            Log.info("docker-image", "no Gitea token stored — skipping gitea-runner install")
        }
        let script = lines.joined(separator: "\n\n")

        let dockerBin = DockerRuntime.resolvedBinaryPath

        // 1. Boot a scratch container from the base image.
        let scratch = "orchard-prepare-tmp-\(Int(Date().timeIntervalSince1970))"
        Log.info("docker-image", "starting scratch container from \(image)")
        _ = try await shell.run([dockerBin, "run", "--detach", "--name", scratch, image,
                                 "/bin/bash", "-lc", "while true; do sleep 3600; done"])

        do {
            // 2. Wait until it answers exec (the daemon may pull the image first).
            try await waitUntilReady(scratch, dockerBin: dockerBin)

            // 3. Inject the agents.
            Log.info("docker-image", "installing runner agents")
            let exec = try await shell.run([dockerBin, "exec", scratch, "/bin/bash", "-lc", script])
            guard exec.succeeded else {
                throw ContainerImageError.provisioningFailed(String(exec.stderr.prefix(500)))
            }

            // 4. Commit the filesystem to the target tag.
            Log.info("docker-image", "committing target image \(target)")
            let commit = try await shell.run([dockerBin, "commit", scratch, target])
            guard commit.succeeded else {
                throw ContainerImageError.provisioningFailed("docker commit failed: \(String(commit.stderr.prefix(500)))")
            }
        } catch {
            try? await shell.run([dockerBin, "rm", "--force", scratch])
            throw error
        }

        // 5. Clean up the scratch container.
        _ = try? await shell.run([dockerBin, "rm", "--force", scratch])
        Log.info("docker-image", "prepared docker image '\(target)' is ready")
        return target
    }

    /// Polls `docker exec true` until the scratch container accepts exec.
    func waitUntilReady(_ id: String, dockerBin: String, timeout: TimeInterval = 120, pollInterval: TimeInterval = 2) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            let probe = try await shell.run([dockerBin, "exec", id, "/bin/true"])
            if probe.succeeded { return }
            try? await Task.sleep(nanoseconds: UInt64(pollInterval * 1_000_000_000))
        }
        throw ContainerImageError.provisioningFailed("scratch container never became ready for exec within \(Int(timeout))s")
    }
}
