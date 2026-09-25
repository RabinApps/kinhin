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

    public init(tart: TartControlling, ssh: SSHExecuting) {
        self.tart = tart
        self.ssh = ssh
    }

    public struct Options {
        public var source: String
        public var target: String
        public var runnerVersion: String
        public var giteaRunnerVersion: String
        public var user: String
        /// Token presence overrides for tests (nil = probe the Keychain).
        public var hasGitHubToken: Bool?
        public var hasGiteaToken: Bool?
        /// Host path to a user script baked into the image after the runner
        /// agents are installed (toolchains etc.). nil = no user script.
        public var provisionScriptPath: String?
        /// Timeout for the user provision script's SSH exec (seconds) —
        /// installing heavy toolchains is slow, so it gets its own budget
        /// separate from the 900 s agent install.
        public var provisionTimeout: TimeInterval
        /// Managed toolchains (`toolchains:` config section) baked after the
        /// runner agents install, before the user provision script. nil = none.
        public var toolchains: kinhinConfig.ToolchainsConfig?
        /// Timeout for the managed toolchain install's SSH exec (seconds).
        public var toolchainTimeout: TimeInterval

        public init(
            source: String = ImagePreparer.defaultSource, target: String = ImagePreparer.defaultTarget,
            runnerVersion: String = ImagePreparer.defaultRunnerVersion,
            giteaRunnerVersion: String = ImagePreparer.defaultGiteaRunnerVersion, user: String = "admin",
            hasGitHubToken: Bool? = nil, hasGiteaToken: Bool? = nil, provisionScriptPath: String? = nil,
            provisionTimeout: TimeInterval = 1800, toolchains: kinhinConfig.ToolchainsConfig? = nil,
            toolchainTimeout: TimeInterval = 1800
        ) {
            self.source = source
            self.target = target
            self.runnerVersion = runnerVersion
            self.giteaRunnerVersion = giteaRunnerVersion
            self.user = user
            self.hasGitHubToken = hasGitHubToken
            self.hasGiteaToken = hasGiteaToken
            self.provisionScriptPath = provisionScriptPath
            self.provisionTimeout = provisionTimeout
            self.toolchains = toolchains
            self.toolchainTimeout = toolchainTimeout
        }
    }

    /// Full prepare pipeline. Slow (minutes); progress is logged.
    public func run(_ options: Options) async throws {
        let tmp = "kinhin-prepare-tmp-\(Int(Date().timeIntervalSince1970))"
        defer {
            Task {
                try? await tart.stop(name: tmp); try? await tart.delete(name: tmp)
            }
        }

        // Resolve agent versions from the release feeds (pinned fallback
        // when offline) so images pick up new runner releases without an
        // kinhin update.
        let versions = await RunnerVersionResolver().resolve()

        // Token-gated provisioning: an agent is baked in ONLY when the user
        // has a credential for that platform. No GitHub PAT → no GitHub
        // agent; no Gitea token → no gitea runner. Both missing → fail loudly.
        let hasGitHubToken = options.hasGitHubToken ?? (KeychainTokenStore.load(forge: .github) != nil)
        let hasGiteaToken = options.hasGiteaToken ?? (KeychainTokenStore.load(forge: .gitea) != nil)
        guard hasGitHubToken || hasGiteaToken else {
            throw ImageError.noCredentials(
                "store at least one platform token first (kinhin auth set / kinhin auth set --gitea)")
        }

        // Validate the user provision script up front: a broken path must
        // fail before the multi-gigabyte image download, not after it.
        let provisionScript = try Self.resolveProvisionScript(options.provisionScriptPath)
        if let provisionScript {
            Log.info("image", "user provision script will be baked: \(provisionScript.path)")
        }

        var scripts: [String] = [RunnerBootstrap.prepareScript()]
        if hasGitHubToken {
            Log.info("image", "GitHub PAT found — baking actions-runner \(versions.github)")
            scripts.append(RunnerBootstrap.installScript(runnerVersion: versions.github))
        } else {
            Log.info("image", "no GitHub PAT stored — skipping actions-runner install")
        }
        if hasGiteaToken {
            Log.info("image", "Gitea token found — baking gitea-runner \(versions.gitea)")
            scripts.append(RunnerBootstrap.giteaRunnerInstallScript(version: versions.gitea))
        } else {
            Log.info("image", "no Gitea token stored — skipping gitea-runner install")
        }
        let script = scripts.joined(separator: "\n\n")

        Log.info("image", "ensuring base image \(options.source) is present (this can download gigabytes once)")
        try await tart.pull(image: options.source)

        Log.info("image", "cloning to scratch VM \(tmp)")
        try await tart.clone(source: options.source, to: tmp)

        // Cache upkeep: sweep stale entries before this prepare writes
        // through the cache (noop unless age/size limits trip).
        let policy = ToolchainCachePolicy(from: options.toolchains)
        ToolchainCachePruner().prune(policy: policy)

        // Always share the host toolchain cache into the scratch VM: every
        // prepare write-through (brew, mise, npm, fvm) lands in one cache
        // that later prepares and runner VMs reuse. Best-effort: scripts
        // skip the cache gracefully when the share is not visible.
        let cacheMounts = [ToolchainCacheMount.guestPath]
        do {
            try FileManager.default.createDirectory(at: Paths.toolchainCache, withIntermediateDirectories: true)
        } catch {
            Log.warn(
                "image", "could not create toolchain cache dir (\(error.localizedDescription)); continuing without it")
        }

        Log.info("image", "booting scratch VM (host toolchain cache shared via virtiofs)")
        try await tart.run(name: tmp, mounts: cacheMounts)
        let ip = try await tart.ip(of: tmp, timeout: 300)
        Log.info("image", "scratch VM at \(ip); injecting runner agent + tweaks")

        let result = try await ssh.exec(vm: tmp, user: options.user, ip: ip, script: script, timeout: 900)
        guard result.succeeded else {
            throw ImageError.provisioningFailed(String(result.stderr.prefix(500)))
        }
        Log.info("image", "agent provisioning done")

        // Managed toolchains (toolchains: config): install + pin via the
        // catalog, with the cache share mounted. Failure aborts the prepare
        // so the previous target image stays intact. The user provision
        // script still runs afterwards and can layer/override on top.
        if let toolchains = options.toolchains {
            let selection = ToolchainCatalog.selection(from: toolchains, mountPath: ToolchainCacheMount.guestPath)
            let managed = RunnerBootstrap.managedToolchainsInstallScript(
                selection: selection, mountPath: ToolchainCacheMount.guestPath)
            Log.info(
                "image",
                "installing managed toolchains (\(selection.miseSpecs.count) mise spec(s), \(selection.brewFormulas.count) brew formula(s), \(selection.npmPackages.count) npm global(s))"
            )
            let provisioned = try await ssh.exec(
                vm: tmp, user: options.user, ip: ip, script: managed, timeout: options.toolchainTimeout)
            guard provisioned.succeeded else {
                throw ImageError.provisioningFailed(
                    "managed toolchain install failed: \(String(provisioned.stderr.prefix(500)))")
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
                    "user provision script failed: \(String(provisioned.stderr.prefix(500)))")
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

    // MARK: User provision script

    /// Validates and reads the user provision script before any slow work:
    /// `~`/`~/` expands, the file must exist, be readable, and be non-empty.
    static func resolveProvisionScript(_ path: String?) throws -> (path: String, content: String)? {
        guard let raw = path?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else { return nil }
        let expanded = expandingTilde(in: raw)
        guard let content = try? String(contentsOfFile: expanded, encoding: .utf8) else {
            throw ImageError.provisionScriptUnreadable(path: expanded, reason: "file missing or unreadable")
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

    public enum ImageError: LocalizedError {
        case provisioningFailed(String)
        case noCredentials(String)
        case provisionScriptUnreadable(path: String, reason: String)

        public var errorDescription: String? {
            switch self {
            case .provisioningFailed(let why): return "image provisioning failed: \(why)"
            case .noCredentials(let why): return "no platform credentials: \(why)"
            case .provisionScriptUnreadable(let path, let why): return "user provision script '\(path)': \(why)"
            }
        }
    }
}
