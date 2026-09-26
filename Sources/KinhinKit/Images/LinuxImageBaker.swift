import Foundation

/// Options shared by every Linux container image bake (Docker and Apple
/// container).
public struct LinuxImageOptions {
    public var image: String
    public var target: String
    public var user: String
    /// Managed toolchains (`toolchains:` config section) baked after the
    /// runner agents install, before the image is committed. nil = none.
    public var toolchains: KinhinConfig.ToolchainsConfig?
    /// Timeout for the managed toolchain install exec (seconds) —
    /// installing heavy toolchains is slow.
    var toolchainTimeout: TimeInterval
    /// Token presence overrides for tests (nil = probe the Keychain).
    public var hasGitHubToken: Bool?
    public var hasGiteaToken: Bool?
    /// Architecture of the image being baked. Anything but arm64 (native on
    /// Apple Silicon) is Docker-only and runs under emulation.
    public var platform: LinuxPlatform

    public init(
        image: String, target: String, user: String = "admin", toolchains: KinhinConfig.ToolchainsConfig? = nil,
        toolchainTimeout: TimeInterval = 1800, hasGitHubToken: Bool? = nil, hasGiteaToken: Bool? = nil,
        platform: LinuxPlatform = .arm64
    ) {
        self.platform = platform
        self.image = image
        self.target = target
        self.user = user
        self.toolchains = toolchains
        self.toolchainTimeout = toolchainTimeout
        self.hasGitHubToken = hasGitHubToken
        self.hasGiteaToken = hasGiteaToken
    }
}

extension LinuxImageOptions {
    /// Base image for re-baking `configured` in place. A rebuild starts from the
    /// previous bake so it stays incremental, but the first bake has nothing
    /// local to start from, and `configured` is only a name kinhin gives its
    /// own output — not something a registry has. Fall back to `fallback`.
    public static func baseImage(
        configured: String, localImages: [String], fallback: String = LinuxBaseImage.defaultReference
    ) -> String {
        let present = localImages.contains { $0 == configured || $0.hasPrefix("\(configured):") }
        return present ? configured : fallback
    }
}

/// The bake pipeline shared by `DockerImagePreparer` and
/// `ContainerImagePreparer`: boot a scratch container from the base image
/// with the host toolchain cache bind-mounted, inject the token-gated runner
/// agents, optionally bake managed toolchains, commit to the target tag, and
/// remove the scratch container. Only the CLI verbs and the commit step differ
/// per backend, so those live in `Backend`.
struct LinuxImageBaker {
    struct Backend {
        /// Log component, e.g. "docker-image".
        let logTag: String
        /// Human noun for log lines, e.g. "docker".
        let displayName: String
        let binary: String
        /// Verb that force-removes a container ("rm" for docker, "delete" for container).
        let removeVerb: String
        /// Given stderr from a failed scratch start, fixes a known, recoverable
        /// cause (returns true, and the start is retried once). nil = none.
        var recoverStartFailure: ((_ shell: ShellRunning, _ stderr: String) async -> Bool)? = nil
        /// Turns the scratch container into the tagged target image.
        let commit: (_ shell: ShellRunning, _ scratch: String, _ target: String) async throws -> Void
    }

    let shell: ShellRunning
    let backend: Backend

    func prepare(_ options: LinuxImageOptions, versions: RunnerVersionResolver.Versions) async throws -> String {
        let tag = backend.logTag
        // Token-gated provisioning: identical policy to the VM path.
        let hasGitHubToken = options.hasGitHubToken ?? AccountTokens.anyStored(for: .github)
        // Forgejo uses the gitea-runner binary: bake it when either
        // Gitea-family platform has a token.
        let hasGiteaToken = options.hasGiteaToken ?? (AccountTokens.anyStored(for: .gitea) || AccountTokens.anyStored(for: .forgejo))
        guard hasGitHubToken || hasGiteaToken else {
            throw ImageError.noCredentials(
                "store at least one platform token first (kinhin auth set / kinhin auth set --gitea)")
        }

        var lines: [String] = []
        if hasGitHubToken {
            Log.info(tag, "GitHub PAT found — baking actions-runner \(versions.github)")
            lines.append(
                RunnerBootstrap.linuxGitHubAgentInstallScript(
                    runnerVersion: versions.github, arch: options.platform.githubRunnerArch))
        } else {
            Log.info(tag, "no GitHub PAT stored — skipping actions-runner install")
        }
        if hasGiteaToken {
            Log.info(tag, "Gitea token found — baking gitea-runner \(versions.gitea)")
            lines.append(
                RunnerBootstrap.linuxGiteaRunnerInstallScript(
                    version: versions.gitea, arch: options.platform.giteaRunnerArch))
        } else {
            Log.info(tag, "no Gitea token stored — skipping gitea-runner install")
        }
        let script = lines.joined(separator: "\n\n")
        let bin = backend.binary

        // Cache upkeep: sweep stale entries before this bake writes through
        // the cache (noop unless age/size limits trip).
        ToolchainCachePruner().prune(policy: ToolchainCachePolicy(from: options.toolchains))

        // Always bind-mount the host toolchain cache into the scratch
        // container: every prepare write-through (apt, mise, npm) lands in
        // one cache that later bakes and runner containers reuse.
        do {
            try FileManager.default.createDirectory(at: Paths.toolchainCache, withIntermediateDirectories: true)
        } catch {
            Log.warn(tag, "could not create toolchain cache dir (\(error.localizedDescription)); continuing without it")
        }

        // 1. Boot a scratch container from the base image, with the host
        //    cache bind-mounted (`<bin> run -v host:guest`).
        let scratch = "kinhin-prepare-tmp-\(Int(Date().timeIntervalSince1970))"
        Log.info(tag, "starting scratch container from \(options.image) (host toolchain cache bind-mounted)")
        var startArgv = [bin, "run", "--detach"]
        // Native arm64 keeps the argv unchanged; anything else is pinned
        // explicitly so the scratch container (and the committed image) match.
        if options.platform != .arm64 {
            Log.warn(tag, LinuxPlatform.emulationNotice)
            startArgv += ["--platform", options.platform.rawValue]
        }
        startArgv += [
            "--volume", ToolchainCacheMount.volumeSpec(host: Paths.toolchainCache.path),
            // POSIX sh, not bash: minimal non-Debian images (Alpine) have no bash,
            // and the apt-get check below should be what rejects them, clearly.
            "--name", scratch, options.image,
            "/bin/sh", "-c", "while true; do sleep 3600; done",
        ]
        var started = try await shell.run(startArgv)
        if !started.succeeded, let recover = backend.recoverStartFailure, await recover(shell, started.stderr) {
            started = try await shell.run(startArgv)
        }
        // Fail here, with the CLI's own reason (missing image, registry
        // auth, ...), instead of polling exec for two minutes.
        guard started.succeeded else {
            // CLIs print progress before the error; the last line is the reason.
            let lines = started.stderr.split(whereSeparator: \.isNewline)
            let reason = String((lines.last ?? "no error output").suffix(500))
            throw ImageError.containerProvisioningFailed(
                "could not start a container from '\(options.image)': \(reason)")
        }

        do {
            // 2. Wait until it answers exec.
            try await waitUntilReady(scratch)

            // The install scripts below use apt-get; say so now instead of
            // failing after a long download on an Alpine or Fedora base.
            let apt = try await shell.run([bin, "exec", scratch, "/bin/sh", "-c", "command -v apt-get"])
            guard apt.succeeded else {
                throw ImageError.containerProvisioningFailed(
                    "'\(options.image)' isn't Debian/Ubuntu-based — kinhin's install scripts need apt-get. Pick a Debian or Ubuntu base image."
                )
            }

            // 3. Inject the agents.
            Log.info(tag, "installing runner agents")
            let exec = try await shell.run([bin, "exec", scratch, "/bin/bash", "-lc", script])
            guard exec.succeeded else {
                throw ImageError.containerProvisioningFailed(exec.failureExcerpt)
            }

            // 4. Managed toolchains (toolchains: config): install + pin via
            //    the catalog, with the cache bind mount visible at the guest
            //    path. Failure aborts the bake so the previous target image
            //    stays intact.
            if let toolchains = options.toolchains {
                try await bakeToolchains(toolchains, into: scratch)
            }

            // 5. Commit the filesystem to the target tag.
            Log.info(tag, "committing target image \(options.target)")
            try await backend.commit(shell, scratch, options.target)
        } catch {
            await removeScratch(scratch)
            throw error
        }

        // 6. Clean up the scratch container.
        await removeScratch(scratch)
        Log.info(tag, "prepared \(backend.displayName) image '\(options.target)' is ready")
        return options.target
    }

    private func bakeToolchains(_ toolchains: KinhinConfig.ToolchainsConfig, into scratch: String) async throws {
        let tag = backend.logTag
        let selection = ToolchainCatalog.selection(
            from: toolchains, platform: .linux, mountPath: ToolchainCacheMount.linuxGuestPath)
        let managed = RunnerBootstrap.linuxManagedToolchainsInstallScript(
            selection: selection, mountPath: ToolchainCacheMount.linuxGuestPath)
        Log.info(
            tag,
            "installing managed toolchains (\(selection.miseSpecs.count) mise spec(s), \(selection.aptPackages.count) apt package(s), \(selection.npmPackages.count) npm global(s); \(selection.skippedEntries.count) macOS-only entr(y/ies) skipped)"
        )
        let provisioned = try await shell.run([backend.binary, "exec", scratch, "/bin/bash", "-lc", managed])
        guard provisioned.succeeded else {
            throw ImageError.containerProvisioningFailed(
                "managed toolchain install failed: \(provisioned.failureExcerpt)")
        }
        let tail = String(provisioned.stdout.trimmingCharacters(in: .whitespacesAndNewlines).suffix(400))
        if !tail.isEmpty {
            Log.info(tag, "managed toolchain output (tail): \(tail)")
        }
        Log.info(tag, "managed toolchains baked into the image")
    }

    private func removeScratch(_ scratch: String) async {
        await bestEffortAsync(backend.logTag, "removing scratch container \(scratch)") {
            _ = try await shell.run([backend.binary, backend.removeVerb, "--force", scratch])
        }
    }

    /// Polls `<bin> exec true` until the scratch container accepts exec.
    func waitUntilReady(_ id: String, timeout: TimeInterval = 120, pollInterval: TimeInterval = 2) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            let probe = try await shell.run([backend.binary, "exec", id, "/bin/true"])
            if probe.succeeded { return }
            try await Task.sleep(for: .seconds(pollInterval))
        }
        throw ImageError.containerProvisioningFailed(
            "scratch container never became ready for exec within \(Int(timeout))s")
    }
}
