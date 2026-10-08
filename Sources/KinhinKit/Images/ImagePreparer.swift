import Foundation

/// Builds the local base image that runner VMs clone from.
public struct ImagePreparer: Sendable {
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
    var guestKeyAttempts = 60
    var guestKeyRetryDelay: Duration = .seconds(1)
    /// How long to ask the guest agent for a fresh SSH host key before the
    /// bake connects without host key verification; tests shorten these.
    var hostKeyWindow: TimeInterval = 30
    var hostKeyInterval: Duration = .seconds(2)

    public init(tart: TartControlling, ssh: SSHExecuting) {
        self.tart = tart
        self.ssh = ssh
    }

    public struct Options: Sendable {
        public var source: String
        public var target: String
        public var runnerVersion: String
        var giteaRunnerVersion: String
        public var user: String
        /// Forges that count as having a stored token, replacing the Keychain
        /// probe (tests). nil = probe the Keychain for every forge.
        public var storedTokens: Set<ForgeID>?
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
            storedTokens: Set<ForgeID>? = nil, provisionScriptPath: String? = nil,
            provisionTimeout: TimeInterval = 1800, toolchains: KinhinConfig.ToolchainsConfig? = nil,
            toolchainTimeout: TimeInterval = 1800, guestOS: GuestOS? = nil, shareCache: Bool = true,
            cachePolicy: KinhinConfig.ToolchainCacheConfig? = nil, cacheScope: String? = nil
        ) {
            self.source = source
            self.target = target
            self.runnerVersion = runnerVersion
            self.giteaRunnerVersion = giteaRunnerVersion
            self.user = user
            self.storedTokens = storedTokens
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

    /// Full prepare pipeline. Slow (minutes); progress is logged. Cancelling
    /// the calling task stops the bake at the next phase boundary: the scratch
    /// VM is stopped and deleted (uncancellable — see below), the previous
    /// target image is left untouched, and `CancellationError` rethrows.
    public func run(_ options: Options) async throws {
        await sweepLeftoverScratchVMs()
        let tmp = Self.scratchPrefix + String(Int(Date().timeIntervalSince1970))
        let tart = self.tart
        do {
            try await prepareScratchVM(options, scratch: tmp)
        } catch {
            // Clean up before the error reaches the caller — cancellation
            // included. The teardown runs in a fresh task: from a cancelled
            // task every shell call is refused (`Shell` throws
            // CancellationError before starting the child), which would skip
            // the very cleanup that cancellation requires (seen live: a
            // cancelled bake left kinhin-prepare-tmp-* on disk).
            try await withoutCancellation {
                await ssh.forgetHostKey(vm: tmp)
                await bestEffortAsync(tmp, "stopping scratch VM") { try await tart.stop(name: tmp) }
                await bestEffortAsync(tmp, "deleting scratch VM") { try await tart.delete(name: tmp) }
            }
            if error is CancellationError {
                Log.info("image", "build cancelled — scratch VM removed; the previous image was not modified")
            }
            throw error
        }
        // Success: the scratch VM was already stopped for the commit, and its
        // disk is an APFS clone peer of the target's — deleting it is safe.
        // Uncancelled like the failure path: a cancel landing right here must
        // not leak the scratch VM.
        try await withoutCancellation {
            await ssh.forgetHostKey(vm: tmp)
            await bestEffortAsync(tmp, "deleting scratch VM") { try await tart.delete(name: tmp) }
        }
    }

    // MARK: - Scratch sweep

    /// The name prefix of the temporary scratch VM a bake clones into
    /// (`kinhin-prepare-tmp-<unix-time>`); the pre-bake sweep and `kinhin
    /// cleanup` recognize leftovers by it. Container bakes (Docker and Apple
    /// container) name their scratch container the same way.
    public static let scratchPrefix = "kinhin-prepare-tmp-"

    /// Removes scratch VMs left behind by earlier bakes that crashed or were
    /// killed before their cleanup ran. Runs before every bake, so orphans
    /// never accumulate disk. Best effort: a failed sweep is logged and the
    /// bake proceeds; a failed listing must never read as "no leftovers".
    func sweepLeftoverScratchVMs() async {
        let locals: [TartVM]
        do {
            locals = try await tart.list()
        } catch {
            Log.warn("image", "could not list VMs for the scratch sweep: \(error.localizedDescription)")
            return
        }
        for name in locals.map(\.name).filter({ $0.hasPrefix(Self.scratchPrefix) }).sorted() {
            Log.info("image", "removing leftover scratch VM \(name) (from a crashed or killed bake)")
            await bestEffortAsync(name, "stopping leftover scratch VM") { try await tart.stop(name: name) }
            await bestEffortAsync(name, "deleting leftover scratch VM") { try await tart.delete(name: name) }
            await ssh.forgetHostKey(vm: name)
        }
    }

    /// The prepare pipeline body: scratch-VM clone through the final commit.
    /// Throws on the first failure; `run` owns the scratch VM's cleanup.
    private func prepareScratchVM(_ options: Options, scratch tmp: String) async throws {
        let tart = self.tart

        // Token-gated provisioning (see `AgentSelection`): only the agents of
        // forges with a stored credential are baked; none at all fails loudly.
        let selection = try AgentSelection(override: options.storedTokens)

        // Resolve agent versions from the release feeds (pinned fallback
        // when offline) so images pick up new runner releases without a
        // kinhin update. Only the platforms with a token are looked up, and
        // the lookup overlaps the pull and clone below.
        let wantedForges = selection.bakedForges
        async let resolvedVersions = RunnerVersionResolver().resolve(including: wantedForges)

        // Validate the user provision script up front: a broken path must
        // fail before the multi-gigabyte image download, not after it.
        let provisionScript = try Self.resolveProvisionScript(options.provisionScriptPath)
        if let provisionScript {
            Log.info("image", "user provision script will be baked: \(provisionScript.path)")
        }

        // Phase boundaries are where a cancelled bake stops: each check below
        // turns Ctrl-C into a clean unwind at the next safe point.
        try Task.checkCancellation()
        Log.info("image", "ensuring base image \(options.source) is present (this can download gigabytes once)")
        // A locally-created VM (tart create --linux, then OS-installed by
        // hand) is already on disk — `tart pull` would fail on a non-registry
        // reference. Local names contain no registry slash.
        if options.source.contains("/") {
            try await tart.pull(image: options.source)
        } else {
            Log.info("image", "source \(options.source) is a local VM — skipping the registry pull")
        }

        try Task.checkCancellation()
        Log.info("image", "cloning to scratch VM \(tmp)")
        try await tart.clone(source: options.source, to: tmp)

        let versions = await resolvedVersions

        // Cache upkeep: sweep stale entries before this prepare writes
        // through the cache (noop unless age/size limits trip).
        let policy = ToolchainCachePolicy(from: options.cachePolicy)
        ToolchainCachePruner().prune(policy: policy, minInterval: 3600)

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

        try Task.checkCancellation()
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

        // The curated images ship admin/admin with SSH on and the scratch VM
        // sits on a network other VMs share, so close password login now,
        // through the same guest-agent channel, before any SSH connection and
        // before the long downloads below. The prepare script still applies and
        // verifies the hardening (`sshd -T`) over SSH, so a failure here only
        // narrows the protection to the old window instead of failing the bake.
        if keyInstallFailure == nil {
            do {
                try await tart.hardenGuestSSH(vm: tmp)
                Log.info("image", "SSH password login turned off in the scratch VM")
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                Log.warn(
                    "image",
                    "could not turn off SSH password login through the guest agent (\(error.localizedDescription)); the prepare script retries it over SSH"
                )
            }
        }
        // Give the scratch VM its own SSH host key, learned over the agent
        // channel, so the SSH calls below cannot be answered by another VM.
        try await GuestHostKeyPinning.pin(
            vm: tmp, tart: tart, ssh: ssh, window: keyInstallFailure == nil ? hostKeyWindow : 0,
            interval: hostKeyInterval)

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
        // git and jq every CI job needs — `actions/checkout`, `git ls-files`,
        // workflow scripts that pipe through jq — even though no agent
        // download installs them. Same list the container bakes install
        // (`LinuxImageBaker`), here through the guest's passwordless sudo.
        // Under its own `set -e`, so a failed apt breaks the bake instead of
        // shipping an image without them.
        if guestOS == .linux {
            scripts.append(
                "set -euo pipefail\n"
                    + RunnerBootstrap.tartLinuxPrerequisitesScript(tools: RunnerBootstrap.ciPrerequisiteTools))
        }
        scripts += selection.installScripts(versions: versions, tag: "image") { agent in
            agent.bake.script(for: guestOS, versions)
        }
        scripts.append(
            try RunnerBootstrap.toolchainHelperInstallScript(
                platform: guestOS.toolchainPlatform, mountPath: guestOS.toolchainMountPath,
                // Containers bake as root; both VM guests run as an admin user.
                sudo: guestOS == .linux ? true : nil)
        )
        let script = scripts.joined(separator: "\n\n")

        try Task.checkCancellation()
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
        try Task.checkCancellation()
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
        try Task.checkCancellation()
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

        // Cancellation stops HERE: once the commit swap begins it runs to
        // completion, in a fresh task that inherits no cancellation — a
        // cancelled caller's shell calls would be refused outright, and stop,
        // delete-target and clone are separate tart calls, so a cancelled
        // swap could leave the target image deleted but unreplaced.
        try Task.checkCancellation()
        let target = options.target
        try await withoutCancellation {
            try await tart.stop(name: tmp)
            if try await tart.list().contains(where: { $0.name == target }) {
                Log.info("image", "replacing existing image \(target)")
                try await tart.delete(name: target)
            }
            try await tart.clone(source: tmp, to: target)
        }
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
