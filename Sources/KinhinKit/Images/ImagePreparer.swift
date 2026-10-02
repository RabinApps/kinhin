import Foundation

/// Builds the local base image that runner VMs clone from.
public struct ImagePreparer {
    public static let defaultSource = "ghcr.io/cirruslabs/macos-tahoe-base:latest"
    public static let defaultTarget = "tahoe-base"
    /// GitHub Actions runner agent version baked into the image when no
    /// release feed is reachable (fallback; `RunnerVersionResolver` normally
    /// supplies the latest from github.com/actions/runner/releases).
    public static let defaultRunnerVersion = RunnerVersionResolver.fallback.github
    /// Gitea runner version fallback (normally resolved from
    /// gitea.com/gitea/runner/releases).
    public static let defaultGiteaRunnerVersion = RunnerVersionResolver.fallback.gitea

    let tart: TartControlling
    let ssh: SSHExecuting
    /// How long to wait for the guest agent to accept the SSH key (it starts a
    /// little after the VM has an IP). Tests shorten these.
    var guestKeyAttempts = 12
    var guestKeyRetryDelay: Duration = .seconds(5)

    public init(tart: TartControlling, ssh: SSHExecuting) {
        self.tart = tart
        self.ssh = ssh
    }

    public struct Options {
        public var source: String
        public var target: String
        public var runnerVersion: String
        var giteaRunnerVersion: String
        public var user: String
        /// Token presence overrides for tests (nil = probe the Keychain).
        public var hasGitHubToken: Bool?
        public var hasGiteaToken: Bool?
        /// nil → any GitLab account has a stored token.
        public var hasGitLabToken: Bool?
        /// nil → any Buildkite account has a stored token.
        public var hasBuildkiteToken: Bool?
        /// nil → any Azure DevOps account has a stored token.
        public var hasAzureDevOpsToken: Bool?
        /// nil → any Bitbucket account has a stored token.
        public var hasBitbucketToken: Bool?
        /// Host path to a user script baked into the image after the runner
        /// agents are installed (toolchains etc.). nil = no user script.
        public var provisionScriptPath: String?
        /// Timeout for the user provision script's SSH exec (seconds) —
        /// installing heavy toolchains is slow, so it gets its own budget
        /// separate from the 900 s agent install.
        var provisionTimeout: TimeInterval
        /// Managed toolchains (`toolchains:` config section) baked after the
        /// runner agents install, before the user provision script. nil = none.
        public var toolchains: KinhinConfig.ToolchainsConfig?
        /// Timeout for the managed toolchain install's SSH exec (seconds).
        var toolchainTimeout: TimeInterval
        /// Guest OS override for the bake (nil = detect via `uname -s` in the
        /// scratch VM). A Linux guest gets the Linux agent binaries and the
        /// Linux toolchain path; macOS keeps the classic bake.
        public var guestOS: GuestOS?
        /// Mount the host toolchain cache into the scratch VM (default). A
        /// per-project bake turns it off unless the project opts in, so a
        /// repo-chosen toolchain set never writes through the shared cache.
        public var shareCache: Bool
        /// Host cache expiry applied before the bake (nil = defaults).
        public var cachePolicy: KinhinConfig.ToolchainCacheConfig?
        /// Scopes the cache share to one project's subdirectory (its image
        /// key); nil shares the whole host cache.
        public var cacheScope: String?

        public init(
            source: String = ImagePreparer.defaultSource, target: String = ImagePreparer.defaultTarget,
            runnerVersion: String = ImagePreparer.defaultRunnerVersion,
            giteaRunnerVersion: String = ImagePreparer.defaultGiteaRunnerVersion, user: String = "admin",
            hasGitHubToken: Bool? = nil, hasGiteaToken: Bool? = nil, hasGitLabToken: Bool? = nil,
            hasBuildkiteToken: Bool? = nil, hasAzureDevOpsToken: Bool? = nil, hasBitbucketToken: Bool? = nil,
            provisionScriptPath: String? = nil,
            provisionTimeout: TimeInterval = 1800, toolchains: KinhinConfig.ToolchainsConfig? = nil,
            toolchainTimeout: TimeInterval = 1800, guestOS: GuestOS? = nil, shareCache: Bool = true,
            cachePolicy: KinhinConfig.ToolchainCacheConfig? = nil, cacheScope: String? = nil
        ) {
            self.source = source
            self.target = target
            self.runnerVersion = runnerVersion
            self.giteaRunnerVersion = giteaRunnerVersion
            self.user = user
            self.hasGitHubToken = hasGitHubToken
            self.hasGiteaToken = hasGiteaToken
            self.hasGitLabToken = hasGitLabToken
            self.hasBuildkiteToken = hasBuildkiteToken
            self.hasAzureDevOpsToken = hasAzureDevOpsToken
            self.hasBitbucketToken = hasBitbucketToken
            self.provisionScriptPath = provisionScriptPath
            self.provisionTimeout = provisionTimeout
            self.toolchains = toolchains
            self.toolchainTimeout = toolchainTimeout
            self.guestOS = guestOS
            self.shareCache = shareCache
            self.cachePolicy = cachePolicy
            self.cacheScope = cacheScope
        }

        /// The options a config asks for: its `base_image:` (else the
        /// default source), provision script and managed toolchains. Every
        /// prepare entry point (CLI, setup checklist, app buttons) starts
        /// here so none of them drops a configured key.
        public init(config cfg: KinhinConfig) {
            self.init(config: cfg, target: cfg.image, baseImage: cfg.baseImage)
        }

        /// The options for one named `images:` entry: its own target name and base.
        public init(config cfg: KinhinConfig, image: KinhinConfig.ImageConfig) {
            self.init(config: cfg, target: image.name, baseImage: image.baseImage)
        }

        private init(config cfg: KinhinConfig, target: String, baseImage: String?) {
            self.init(target: target, provisionScriptPath: cfg.provisionScript, cachePolicy: cfg.toolchainCache)
            if let baseImage {
                // An explicit registry reference is used verbatim (the config
                // template's "a pre-configured tart image" promise);
                // ConfigLoader already validated its shape. Short curated
                // names expand through the catalog; unknown bare names keep
                // the documented default.
                source =
                    baseImage.contains("/")
                    ? baseImage
                    : TartBaseImage.resolveSource(preparedName: baseImage)
            }
        }
    }

    /// Full prepare pipeline. Slow (minutes); progress is logged.
    public func run(_ options: Options) async throws {
        let tmp = "kinhin-prepare-tmp-\(Int(Date().timeIntervalSince1970))"
        let tart = self.tart
        do {
            try await prepareScratchVM(options, scratch: tmp)
        } catch {
            // Clean up before the error reaches the caller: a CLI process
            // exits right after, which would kill a fire-and-forget task and
            // leave the scratch VM behind (seen live: a failed toolchain bake
            // left kinhin-prepare-tmp-* on disk).
            await bestEffortAsync(tmp, "stopping scratch VM") { try await tart.stop(name: tmp) }
            await bestEffortAsync(tmp, "deleting scratch VM") { try await tart.delete(name: tmp) }
            throw error
        }
        // Success: the scratch VM was already stopped for the commit, and its
        // disk is an APFS clone peer of the target's — deleting it is safe.
        await bestEffortAsync(tmp, "deleting scratch VM") { try await tart.delete(name: tmp) }
    }

    /// The prepare pipeline body: scratch-VM clone through the final commit.
    /// Throws on the first failure; `run` owns the scratch VM's cleanup.
    private func prepareScratchVM(_ options: Options, scratch tmp: String) async throws {
        let tart = self.tart

        // Resolve agent versions from the release feeds (pinned fallback
        // when offline) so images pick up new runner releases without an
        // kinhin update.
        let versions = await RunnerVersionResolver().resolve()

        // Token-gated provisioning: an agent is baked in ONLY when the user
        // has a credential for that platform. No GitHub PAT → no GitHub
        // agent; no Gitea token → no gitea runner. Both missing → fail loudly.
        let hasGitHubToken = try options.hasGitHubToken ?? AccountTokens.anyStored(for: .github)
        // Forgejo uses the gitea-runner binary: bake it when either
        // Gitea-family platform has a token.
        let hasGiteaToken =
            try options.hasGiteaToken
            ?? (AccountTokens.anyStored(for: .gitea) || AccountTokens.anyStored(for: .forgejo))
        let hasGitLabToken = try options.hasGitLabToken ?? AccountTokens.anyStored(for: .gitlab)
        let hasBuildkiteToken = try options.hasBuildkiteToken ?? AccountTokens.anyStored(for: .buildkite)
        let hasAzureDevOpsToken = try options.hasAzureDevOpsToken ?? AccountTokens.anyStored(for: .azuredevops)
        let hasBitbucketToken = try options.hasBitbucketToken ?? AccountTokens.anyStored(for: .bitbucket)
        guard
            hasGitHubToken || hasGiteaToken || hasGitLabToken || hasBuildkiteToken || hasAzureDevOpsToken
                || hasBitbucketToken
        else {
            throw ImageError.noCredentials(
                "store at least one platform token first (kinhin auth set / kinhin auth set --gitea / --gitlab / --account NAME)"
            )
        }

        // Validate the user provision script up front: a broken path must
        // fail before the multi-gigabyte image download, not after it.
        let provisionScript = try Self.resolveProvisionScript(options.provisionScriptPath)
        if let provisionScript {
            Log.info("image", "user provision script will be baked: \(provisionScript.path)")
        }

        Log.info("image", "ensuring base image \(options.source) is present (this can download gigabytes once)")
        // A locally-created VM (tart create --linux, then OS-installed by
        // hand) is already on disk — `tart pull` would fail on a non-registry
        // reference. Local names contain no registry slash.
        if options.source.contains("/") {
            try await tart.pull(image: options.source)
        } else {
            Log.info("image", "source \(options.source) is a local VM — skipping the registry pull")
        }

        Log.info("image", "cloning to scratch VM \(tmp)")
        try await tart.clone(source: options.source, to: tmp)

        // Cache upkeep: sweep stale entries before this prepare writes
        // through the cache (noop unless age/size limits trip).
        let policy = ToolchainCachePolicy(from: options.cachePolicy)
        ToolchainCachePruner().prune(policy: policy)

        // Always share the host toolchain cache into the scratch VM: every
        // prepare write-through (brew, mise, npm, fvm) lands in one cache
        // that later prepares and runner VMs reuse. Best-effort: scripts
        // skip the cache gracefully when the share is not visible.
        let cacheMounts =
            options.shareCache ? [ToolchainCacheMount.tartDirectorySpec(scope: options.cacheScope)] : []
        if options.shareCache {
            do {
                try FileManager.default.createDirectory(at: Paths.toolchainCache, withIntermediateDirectories: true)
            } catch {
                Log.warn(
                    "image",
                    "could not create toolchain cache dir (\(error.localizedDescription)); continuing without it")
            }
        }

        Log.info(
            "image",
            options.shareCache
                ? "booting scratch VM (host toolchain cache shared via virtiofs)"
                : "booting scratch VM (no host cache share)")
        try await tart.run(name: tmp, mounts: cacheMounts)
        let ip = try await tart.ip(of: tmp, timeout: 300)

        // Cirrus base images trust no SSH key and SSH here never sends a password,
        // so trust ours through the guest agent first. Best effort: a Linux guest
        // without the agent may already trust a key, so a failure is reported
        // only if the SSH call below then fails too.
        let keyInstallFailure = try await installGuestSSHKey(
            vm: tmp, user: options.user, attempts: guestKeyAttempts, delay: guestKeyRetryDelay)

        // Detect the guest OS (unless overridden) so a tart Linux base VM
        // gets the Linux agent binaries and the Linux toolchain path. The
        // probe is the first SSH exec: it needs the booted scratch VM.
        let guestOS: GuestOS
        if let override = options.guestOS {
            guestOS = override
        } else {
            do {
                guestOS = try await Self.detectGuestOS(vm: tmp, user: options.user, ip: ip, ssh: ssh)
            } catch ImageError.provisioningFailed(let why) {
                guard let keyInstallFailure else { throw ImageError.provisioningFailed(why) }
                throw ImageError.provisioningFailed(
                    "\(why). kinhin also could not install its SSH key in the VM through `tart exec`: \(keyInstallFailure)"
                )
            }
        }
        switch guestOS {
        case .macOS:
            Log.info("image", "macOS guest detected — baking the macOS agents")
        case .linux:
            Log.info("image", "Linux guest detected — baking the Linux agent binaries")
        }

        var scripts: [String] = [guestOS.prepareScript()]
        if hasGitHubToken {
            Log.info("image", "GitHub PAT found — baking actions-runner \(versions.github)")
            switch guestOS {
            case .macOS: scripts.append(RunnerBootstrap.installScript(runnerVersion: versions.github))
            case .linux:
                scripts.append(RunnerBootstrap.tartLinuxGitHubAgentInstallScript(runnerVersion: versions.github))
            }
        } else {
            Log.info("image", "no GitHub PAT stored — skipping actions-runner install")
        }
        if hasGiteaToken {
            Log.info("image", "Gitea token found — baking gitea-runner \(versions.gitea)")
            switch guestOS {
            case .macOS: scripts.append(RunnerBootstrap.giteaRunnerInstallScript(version: versions.gitea))
            case .linux: scripts.append(RunnerBootstrap.tartLinuxGiteaRunnerInstallScript(version: versions.gitea))
            }
        } else {
            Log.info("image", "no Gitea token stored — skipping gitea-runner install")
        }
        if hasGitLabToken {
            Log.info("image", "GitLab token found — baking gitlab-runner \(versions.gitlab)")
            switch guestOS {
            case .macOS: scripts.append(RunnerBootstrap.gitlabRunnerInstallScript(version: versions.gitlab))
            case .linux: scripts.append(RunnerBootstrap.tartLinuxGitLabRunnerInstallScript(version: versions.gitlab))
            }
        } else {
            Log.info("image", "no GitLab token stored — skipping gitlab-runner install")
        }
        if hasBuildkiteToken {
            Log.info("image", "Buildkite token found — baking buildkite-agent \(versions.buildkite)")
            switch guestOS {
            case .macOS: scripts.append(RunnerBootstrap.buildkiteAgentInstallScript(version: versions.buildkite))
            case .linux:
                scripts.append(RunnerBootstrap.tartLinuxBuildkiteAgentInstallScript(version: versions.buildkite))
            }
        } else {
            Log.info("image", "no Buildkite token stored — skipping buildkite-agent install")
        }
        if hasAzureDevOpsToken {
            Log.info("image", "Azure DevOps token found — baking the Azure Pipelines agent \(versions.azure)")
            switch guestOS {
            case .macOS: scripts.append(RunnerBootstrap.azureAgentInstallScript(version: versions.azure))
            case .linux: scripts.append(RunnerBootstrap.tartLinuxAzureAgentInstallScript(version: versions.azure))
            }
        } else {
            Log.info("image", "no Azure DevOps token stored — skipping the Azure Pipelines agent install")
        }
        if hasBitbucketToken {
            Log.info("image", "Bitbucket token found — baking the Bitbucket runner \(versions.bitbucket)")
            switch guestOS {
            case .macOS:
                scripts.append(
                    RunnerBootstrap.bitbucketRunnerInstallScript(
                        version: versions.bitbucket, jdkVersion: versions.bitbucketJDK, jdkPlatform: "aarch64_mac"))
            case .linux:
                scripts.append(
                    RunnerBootstrap.tartLinuxBitbucketRunnerInstallScript(
                        version: versions.bitbucket, jdkVersion: versions.bitbucketJDK))
            }
        } else {
            Log.info("image", "no Bitbucket token stored — skipping the Bitbucket runner install")
        }
        scripts.append(
            try RunnerBootstrap.toolchainHelperInstallScript(
                platform: guestOS.toolchainPlatform, mountPath: guestOS.toolchainMountPath,
                // Containers bake as root; both VM guests run as an admin user.
                sudo: guestOS == .linux ? true : nil)
        )
        let script = scripts.joined(separator: "\n\n")

        Log.info("image", "scratch VM at \(ip); injecting runner agent + tweaks")

        let result = try await ssh.exec(vm: tmp, user: options.user, ip: ip, script: script, timeout: 900)
        guard result.succeeded else {
            throw ImageError.provisioningFailed(result.failureExcerpt)
        }
        Log.info("image", "agent provisioning done")

        // Managed toolchains (toolchains: config): install + pin via the
        // catalog, with the cache share mounted. Failure aborts the prepare
        // so the previous target image stays intact. The user provision
        // script still runs afterwards and can layer/override on top.
        if let toolchains = options.toolchains {
            let selection = ToolchainCatalog.selection(
                from: toolchains, platform: guestOS.toolchainPlatform, mountPath: guestOS.toolchainMountPath)
            let managed = guestOS.managedToolchainsScript(selection: selection, mountPath: guestOS.toolchainMountPath)
            switch guestOS {
            case .macOS:
                Log.info(
                    "image",
                    "installing managed toolchains (\(selection.miseSpecs.count) mise spec(s), \(selection.brewFormulas.count) brew formula(s), \(selection.npmPackages.count) npm global(s))"
                )
            case .linux:
                Log.info(
                    "image",
                    "installing managed toolchains (\(selection.miseSpecs.count) mise spec(s), \(selection.aptPackages.count) apt package(s), \(selection.npmPackages.count) npm global(s); \(selection.skippedEntries.count) macOS-only entr(y/ies) skipped)"
                )
            }
            let provisioned = try await ssh.exec(
                vm: tmp, user: options.user, ip: ip, script: managed, timeout: options.toolchainTimeout)
            guard provisioned.succeeded else {
                throw ImageError.provisioningFailed(
                    "managed toolchain install failed: \(provisioned.failureExcerpt)")
            }
            let tail = String(provisioned.stdout.trimmingCharacters(in: .whitespacesAndNewlines).suffix(400))
            if !tail.isEmpty {
                Log.info("image", "managed toolchain output (tail): \(tail)")
            }
            Log.info("image", "managed toolchains baked into the image")
        }

        // User toolchains: run the provision script verbatim as a second SSH
        // exec, while the scratch VM is still up. Failure aborts the prepare
        // so the previous target image stays intact.
        if let provision = provisionScript {
            Log.info("image", "running user provision script: \(provision.path)")
            let wrapper = Self.provisionWrapperScript(contentBase64: Data(provision.content.utf8).base64EncodedString())
            let provisioned = try await ssh.exec(
                vm: tmp, user: options.user, ip: ip, script: wrapper, timeout: options.provisionTimeout)
            guard provisioned.succeeded else {
                throw ImageError.provisioningFailed(
                    "user provision script failed: \(provisioned.failureExcerpt)")
            }
            // Audit trail: the tail of the script's stdout (version prints
            // etc.) lands in the log, recording what went into this image.
            let tail = String(provisioned.stdout.trimmingCharacters(in: .whitespacesAndNewlines).suffix(400))
            if !tail.isEmpty {
                Log.info("image", "provision script output (tail): \(tail)")
            }
            Log.info("image", "user provision script baked into the image")
        }

        Log.info("image", "provisioning done; stopping scratch VM")

        try await tart.stop(name: tmp)

        // Replace any previous prepared image, then keep the scratch clone
        // around as the new base (linked clones of it stay cheap).
        if try await tart.list().contains(where: { $0.name == options.target }) {
            Log.info("image", "replacing existing image \(options.target)")
            try await tart.delete(name: options.target)
        }
        try await tart.clone(source: tmp, to: options.target)
        Log.info("image", "prepared image '\(options.target)' is ready")
    }

    // MARK: - Guest SSH key

    /// Installs the guest SSH key, retrying while the guest agent comes up (it
    /// starts a little after the VM has an IP). Returns the last failure, or nil.
    func installGuestSSHKey(vm: String, user: String, attempts: Int, delay: Duration) async throws -> String? {
        var failure: String?
        for attempt in 1...attempts {
            do {
                try await tart.installGuestSSHKey(vm: vm, user: user)
                return nil
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                failure = error.localizedDescription
                Log.info("image", "guest SSH key not installed yet (attempt \(attempt)/\(attempts)): \(failure ?? "")")
                if attempt < attempts { try await Task.sleep(for: delay) }
            }
        }
        Log.warn("image", "could not install the guest SSH key: \(failure ?? "unknown error")")
        return failure
    }

    // MARK: - Guest OS detection

    /// Runs `uname -s` in the booted scratch VM. Darwin → macOS, anything
    /// else → Linux. An unrecognized answer is an error: guessing here would
    /// bake the wrong agent binaries into the image.
    static func detectGuestOS(vm: String, user: String, ip: String, ssh: SSHExecuting) async throws -> GuestOS {
        let result = try await ssh.exec(
            vm: vm, user: user, ip: ip, script: GuestOS.probeScript, timeout: 60)
        guard result.succeeded else {
            throw ImageError.provisioningFailed(
                "could not detect the guest OS (`uname -s` failed): \(result.failureExcerpt)")
        }
        guard let os = GuestOS.parse(unameOutput: result.stdout) else {
            throw ImageError.provisioningFailed(
                "unrecognized `uname -s` output: \"\(result.stdout.trimmingCharacters(in: .whitespacesAndNewlines))\" "
                    + "— cannot decide between macOS and Linux agents")
        }
        return os
    }

    // MARK: - User provision script

    /// Validates and reads the user provision script before any slow work:
    /// `~`/`~/` expands, the file must exist, be readable, and be non-empty.
    static func resolveProvisionScript(_ path: String?) throws -> (path: String, content: String)? {
        guard let raw = path?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else { return nil }
        let expanded = expandingTilde(in: raw)
        let content: String
        do {
            content = try String(contentsOfFile: expanded, encoding: .utf8)
        } catch {
            throw ImageError.provisionScriptUnreadable(path: expanded, reason: error.localizedDescription)
        }
        guard !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ImageError.provisionScriptUnreadable(path: expanded, reason: "script is empty")
        }
        return (expanded, content)
    }

    /// Expands a leading `~` / `~/` to the current user's home directory.
    /// No `~username` support — paths are host-local by definition.
    static func expandingTilde(in path: String) -> String {
        if path == "~" { return NSHomeDirectory() }
        if path.hasPrefix("~/") { return NSHomeDirectory() + path.dropFirst() }
        return path
    }

    /// The remote wrapper executed over SSH: decode the embedded script to a
    /// temp file, run it with bash, remove the temp file. `set -e` makes any
    /// script failure propagate as a nonzero SSH exit. The script content is
    /// base64-embedded so it runs verbatim — no shell-escaping of user input.
    static func provisionWrapperScript(contentBase64: String) -> String {
        """
        set -euo pipefail
        echo \(contentBase64) | base64 --decode > /tmp/kinhin-provision.sh
        bash /tmp/kinhin-provision.sh
        rm -f /tmp/kinhin-provision.sh
        """
    }

}
