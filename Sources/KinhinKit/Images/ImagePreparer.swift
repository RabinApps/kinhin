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
    public static let scratchPrefix = InstanceNaming.prefix + "prepare-tmp-"

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

        try await pullAndClone(options, scratch: tmp)
        let versions = await resolvedVersions
        let session = try await bootScratchVM(options, scratch: tmp)

        try Task.checkCancellation()
        Log.info("image", "scratch VM at \(session.ip); injecting runner agent + tweaks")
        try await run(try agentProvisionStep(session, selection: selection, versions: versions), in: session)

        // Managed toolchains, then the user script: each failure aborts the
        // prepare so the previous target image stays intact.
        try Task.checkCancellation()
        if let toolchains = options.toolchains {
            try await run(
                toolchainProvisionStep(session, toolchains: toolchains, timeout: options.toolchainTimeout), in: session)
        }
        try Task.checkCancellation()
        if let provisionScript {
            try await run(userScriptProvisionStep(provisionScript, timeout: options.provisionTimeout), in: session)
        }

        try await commitSwap(scratch: tmp, target: options.target, session: session)
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

    /// The failure for a provision step, with a reachability hint when the
    /// SSH failure itself says the host could not reach the guest VM — as
    /// opposed to an agent or script failing inside the guest. Only the SSH
    /// excerpt is matched: a guest script's own output (`curl` timing out on
    /// an external service) must not trigger the hint. OrbStack and Docker
    /// Desktop's VPN interop share the vnet interface tart uses and
    /// occasionally re-route or claim it, so the remedy points there first.
    static func provisioningFailure(prefix: String?, excerpt: String) -> ImageError {
        let message = (prefix ?? "") + excerpt
        let reach = ["no route to host", "operation timed out", "host is down"].contains {
            excerpt.lowercased().contains($0)
        }
        guard reach else { return .provisioningFailed(message) }
        return .provisioningFailed(
            message + " — the host could not reach the guest VM over its vnet interface. OrbStack or"
                + " Docker Desktop's VPN interop can re-route host↔VM traffic: stop it (or update it) and retry.")
    }

    /// Runs `uname -s` in the booted scratch VM. Darwin → macOS, anything
    /// else → Linux. An unrecognized answer is an error: guessing here would
    /// bake the wrong agent binaries into the image.
    static func detectGuestOS(vm: String, user: String, ip: String, ssh: SSHExecuting) async throws -> GuestOS {
        let result = try await ssh.exec(
            vm: vm, user: user, ip: ip, script: GuestOS.probeScript, timeout: 60)
        guard result.succeeded else {
            throw Self.provisioningFailure(
                prefix: "could not detect the guest OS (`uname -s` failed): ", excerpt: result.failureExcerpt)
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
