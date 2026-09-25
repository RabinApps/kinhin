import Foundation

/// Bakes the runner agents into a Linux OCI image for the Docker runtime:
/// boots a scratch container from the base image (`docker run`), installs the
/// GitHub Actions agent and/or gitea-runner (token-gated, mirroring the VM
/// and Apple-container prepare paths), optionally bakes managed toolchains,
/// commits via `docker commit`, tags the result, and cleans up the scratch
/// container.
///
/// Unlike the Apple-container preparer (which must `container build` because
/// `container` has no commit), Docker's native `commit` keeps this a simple
/// three-command bake with no temp build context.
public struct DockerImagePreparer {
    let shell: ShellRunning

    public init(shell: ShellRunning) {
        self.shell = shell
    }

    public struct Options {
        public var image: String
        public var target: String
        public var user: String
        /// Managed toolchains (`toolchains:` config section) baked after the
        /// runner agents install, before `docker commit`. nil = none.
        public var toolchains: kinhinConfig.ToolchainsConfig?
        /// Timeout for the managed toolchain install exec (seconds) —
        /// installing heavy toolchains is slow.
        public var toolchainTimeout: TimeInterval
        /// Token presence overrides for tests (nil = probe the Keychain).
        public var hasGitHubToken: Bool?
        public var hasGiteaToken: Bool?

        public init(
            image: String, target: String, user: String = "admin", toolchains: kinhinConfig.ToolchainsConfig? = nil,
            toolchainTimeout: TimeInterval = 1800, hasGitHubToken: Bool? = nil, hasGiteaToken: Bool? = nil
        ) {
            self.image = image
            self.target = target
            self.user = user
            self.toolchains = toolchains
            self.toolchainTimeout = toolchainTimeout
            self.hasGitHubToken = hasGitHubToken
            self.hasGiteaToken = hasGiteaToken
        }
    }

    /// Resolve the runner-agent versions from the vendors' feeds (pinned
    /// fallback offline), then run the bake.
    @discardableResult
    public func prepare(_ options: Options) async throws -> String {
        let versions = await RunnerVersionResolver().resolve()
        return try await prepare(options, versions: versions)
    }

    /// Back-compat entry without toolchains.
    @discardableResult
    public func prepare(image: String, target: String, user: String = "admin") async throws -> String {
        try await prepare(.init(image: image, target: target, user: user))
    }

    /// Testable core with injected versions.
    public func prepare(_ options: Options, versions: RunnerVersionResolver.Versions) async throws -> String {
        // Token-gated provisioning: identical policy to the other paths.
        let hasGitHubToken = options.hasGitHubToken ?? (KeychainTokenStore.load(forge: .github) != nil)
        let hasGiteaToken = options.hasGiteaToken ?? (KeychainTokenStore.load(forge: .gitea) != nil)
        guard hasGitHubToken || hasGiteaToken else {
            throw ContainerImageError.noCredentials(
                "store at least one platform token first (kinhin auth set / kinhin auth set --gitea)")
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

        // Cache upkeep: sweep stale entries before this bake writes through
        // the cache (noop unless age/size limits trip).
        let policy = ToolchainCachePolicy(from: options.toolchains)
        ToolchainCachePruner().prune(policy: policy)

        // Always bind-mount the host toolchain cache into the scratch
        // container: every prepare write-through (apt, mise, npm) lands in
        // one cache that later bakes and runner containers reuse.
        do {
            try FileManager.default.createDirectory(at: Paths.toolchainCache, withIntermediateDirectories: true)
        } catch {
            Log.warn(
                "docker-image",
                "could not create toolchain cache dir (\(error.localizedDescription)); continuing without it")
        }

        // 1. Boot a scratch container from the base image, with the host
        //    cache bind-mounted (`docker run -v host:guest`).
        let scratch = "kinhin-prepare-tmp-\(Int(Date().timeIntervalSince1970))"
        let hostCache = Paths.toolchainCache.path
        Log.info("docker-image", "starting scratch container from \(options.image) (host toolchain cache bind-mounted)")
        _ = try await shell.run([
            dockerBin, "run", "--detach",
            "--volume", ToolchainCacheMount.volumeSpec(host: hostCache),
            "--name", scratch, options.image,
            "/bin/bash", "-lc", "while true; do sleep 3600; done",
        ])

        do {
            // 2. Wait until it answers exec (the daemon may pull the image first).
            try await waitUntilReady(scratch, dockerBin: dockerBin)

            // 3. Inject the agents.
            Log.info("docker-image", "installing runner agents")
            let exec = try await shell.run([dockerBin, "exec", scratch, "/bin/bash", "-lc", script])
            guard exec.succeeded else {
                throw ContainerImageError.provisioningFailed(String(exec.stderr.prefix(500)))
            }

            // 4. Managed toolchains (toolchains: config): install + pin via
            //    the catalog, with the cache bind mount visible at the guest
            //    path. Failure aborts the bake so the previous target image
            //    stays intact.
            if let toolchains = options.toolchains {
                let selection = ToolchainCatalog.selection(
                    from: toolchains, platform: .linux, mountPath: ToolchainCacheMount.linuxGuestPath)
                let managed = RunnerBootstrap.linuxManagedToolchainsInstallScript(
                    selection: selection, mountPath: ToolchainCacheMount.linuxGuestPath)
                Log.info(
                    "docker-image",
                    "installing managed toolchains (\(selection.miseSpecs.count) mise spec(s), \(selection.aptPackages.count) apt package(s), \(selection.npmPackages.count) npm global(s); \(selection.skippedEntries.count) macOS-only entr(y/ies) skipped)"
                )
                let provisioned = try await shell.run([dockerBin, "exec", scratch, "/bin/bash", "-lc", managed])
                guard provisioned.succeeded else {
                    throw ContainerImageError.provisioningFailed(
                        "managed toolchain install failed: \(String(provisioned.stderr.prefix(500)))")
                }
                let tail = String(provisioned.stdout.trimmingCharacters(in: .whitespacesAndNewlines).suffix(400))
                if !tail.isEmpty {
                    Log.info("docker-image", "managed toolchain output (tail): \(tail)")
                }
                Log.info("docker-image", "managed toolchains baked into the image")
            }

            // 5. Commit the filesystem to the target tag.
            Log.info("docker-image", "committing target image \(options.target)")
            let commit = try await shell.run([dockerBin, "commit", scratch, options.target])
            guard commit.succeeded else {
                throw ContainerImageError.provisioningFailed(
                    "docker commit failed: \(String(commit.stderr.prefix(500)))")
            }
        } catch {
            _ = try? await shell.run([dockerBin, "rm", "--force", scratch])
            throw error
        }

        // 6. Clean up the scratch container.
        _ = try? await shell.run([dockerBin, "rm", "--force", scratch])
        Log.info("docker-image", "prepared docker image '\(options.target)' is ready")
        return options.target
    }

    /// Polls `docker exec true` until the scratch container accepts exec.
    func waitUntilReady(_ id: String, dockerBin: String, timeout: TimeInterval = 120, pollInterval: TimeInterval = 2)
        async throws
    {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            let probe = try await shell.run([dockerBin, "exec", id, "/bin/true"])
            if probe.succeeded { return }
            try? await Task.sleep(nanoseconds: UInt64(pollInterval * 1_000_000_000))
        }
        throw ContainerImageError.provisioningFailed(
            "scratch container never became ready for exec within \(Int(timeout))s")
    }
}
