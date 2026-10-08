import Foundation

// The phases of the prepare pipeline (`ImagePreparer.prepareScratchVM`), one
// function each: pull + clone, boot a trusted scratch VM, the provisioning
// steps, and the commit swap.

/// A booted, SSH-reachable scratch VM and what was learned about its guest.
struct ScratchVMSession: Sendable {
    let vm: String
    let user: String
    let ip: String
    let guestOS: GuestOS
}

/// One SSH exec of the provisioning stage (agents, managed toolchains, the
/// user script): the script, its time budget and how it reports.
struct ProvisionStep: Sendable {
    let script: String
    let timeout: TimeInterval
    /// Prefixed to the failure excerpt (nil: the excerpt alone).
    let failurePrefix: String?
    /// Log label for the tail of the script's stdout, an audit trail of what
    /// went into the image (nil: not logged).
    let outputLabel: String?
    /// Logged once the step succeeded.
    let doneMessage: String
}

extension ImagePreparer {
    // MARK: - Pull and clone

    /// Ensures the base image is present and clones it into the scratch VM.
    func pullAndClone(_ options: Options, scratch tmp: String) async throws {
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
    }

    // MARK: - Scratch VM session

    /// Boots the scratch VM with the host toolchain cache shared in, trusts
    /// our SSH key, closes password login, pins the host key and detects the
    /// guest OS.
    func bootScratchVM(_ options: Options, scratch tmp: String) async throws -> ScratchVMSession {
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
        return ScratchVMSession(vm: tmp, user: options.user, ip: ip, guestOS: guestOS)
    }

    // MARK: - Provisioning

    /// The runner agents (token-gated), the toolchain helper and the guest's
    /// base tweaks, as one script.
    func agentProvisionStep(
        _ session: ScratchVMSession, selection: AgentSelection, versions: RunnerVersionResolver.Versions
    ) throws -> ProvisionStep {
        let guestOS = session.guestOS
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
        return ProvisionStep(
            script: scripts.joined(separator: "\n\n"), timeout: 900, failurePrefix: nil, outputLabel: nil,
            doneMessage: "agent provisioning done")
    }

    /// Managed toolchains (`toolchains:` config): install + pin via the
    /// catalog, with the cache share mounted. The user provision script still
    /// runs afterwards and can layer/override on top.
    func toolchainProvisionStep(
        _ session: ScratchVMSession, toolchains: KinhinConfig.ToolchainsConfig, timeout: TimeInterval
    ) -> ProvisionStep {
        let guestOS = session.guestOS
        let selection = ToolchainCatalog.selection(
            from: toolchains, platform: guestOS.toolchainPlatform, mountPath: guestOS.toolchainMountPath)
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
        return ProvisionStep(
            script: guestOS.managedToolchainsScript(selection: selection, mountPath: guestOS.toolchainMountPath),
            timeout: timeout, failurePrefix: "managed toolchain install failed: ",
            outputLabel: "managed toolchain output (tail): ", doneMessage: "managed toolchains baked into the image")
    }

    /// The user provision script, run verbatim.
    func userScriptProvisionStep(_ script: (path: String, content: String), timeout: TimeInterval) -> ProvisionStep {
        Log.info("image", "running user provision script: \(script.path)")
        return ProvisionStep(
            script: Self.provisionWrapperScript(contentBase64: Data(script.content.utf8).base64EncodedString()),
            timeout: timeout, failurePrefix: "user provision script failed: ",
            outputLabel: "provision script output (tail): ", doneMessage: "user provision script baked into the image")
    }

    /// Runs one step over SSH. A failure aborts the prepare so the previous
    /// target image stays intact.
    func run(_ step: ProvisionStep, in session: ScratchVMSession) async throws {
        let result = try await ssh.exec(
            vm: session.vm, user: session.user, ip: session.ip, script: step.script, timeout: step.timeout)
        guard result.succeeded else {
            throw ImageError.provisioningFailed((step.failurePrefix ?? "") + result.failureExcerpt)
        }
        if let label = step.outputLabel {
            // Audit trail: the tail of the script's stdout (version prints
            // etc.) lands in the log, recording what went into this image.
            let tail = String(result.stdout.trimmingCharacters(in: .whitespacesAndNewlines).suffix(400))
            if !tail.isEmpty { Log.info("image", label + tail) }
        }
        Log.info("image", step.doneMessage)
    }

    // MARK: - Commit swap

    /// Stops the scratch VM and replaces `target` with a clone of it.
    func commitSwap(scratch tmp: String, target: String) async throws {
        Log.info("image", "provisioning done; stopping scratch VM")
        // Cancellation stops HERE: once the commit swap begins it runs to
        // completion, in a fresh task that inherits no cancellation — a
        // cancelled caller's shell calls would be refused outright, and stop,
        // delete-target and clone are separate tart calls, so a cancelled
        // swap could leave the target image deleted but unreplaced.
        try Task.checkCancellation()
        let tart = self.tart
        try await withoutCancellation {
            try await tart.stop(name: tmp)
            if try await tart.list().contains(where: { $0.name == target }) {
                Log.info("image", "replacing existing image \(target)")
                try await tart.delete(name: target)
            }
            try await tart.clone(source: tmp, to: target)
        }
        Log.info("image", "prepared image '\(target)' is ready")
    }
}
