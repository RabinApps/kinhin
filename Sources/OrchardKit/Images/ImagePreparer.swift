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

        public init(source: String = ImagePreparer.defaultSource, target: String = ImagePreparer.defaultTarget, runnerVersion: String = ImagePreparer.defaultRunnerVersion, giteaRunnerVersion: String = ImagePreparer.defaultGiteaRunnerVersion, user: String = "admin", hasGitHubToken: Bool? = nil, hasGiteaToken: Bool? = nil) {
            self.source = source
            self.target = target
            self.runnerVersion = runnerVersion
            self.giteaRunnerVersion = giteaRunnerVersion
            self.user = user
            self.hasGitHubToken = hasGitHubToken
            self.hasGiteaToken = hasGiteaToken
        }
    }

    /// Full prepare pipeline. Slow (minutes); progress is logged.
    public func run(_ options: Options) async throws {
        let tmp = "orchard-prepare-tmp-\(Int(Date().timeIntervalSince1970))"
        defer {
            Task { try? await tart.stop(name: tmp) ; try? await tart.delete(name: tmp) }
        }

        // Resolve agent versions from the release feeds (pinned fallback
        // when offline) so images pick up new runner releases without an
        // Orchard update.
        let versions = await RunnerVersionResolver().resolve()

        // Token-gated provisioning: an agent is baked in ONLY when the user
        // has a credential for that platform. No GitHub PAT → no GitHub
        // agent; no Gitea token → no gitea runner. Both missing → fail loudly.
        let hasGitHubToken = options.hasGitHubToken ?? (KeychainTokenStore.load(forge: .github) != nil)
        let hasGiteaToken = options.hasGiteaToken ?? (KeychainTokenStore.load(forge: .gitea) != nil)
        guard hasGitHubToken || hasGiteaToken else {
            throw ImageError.noCredentials("store at least one platform token first (orchard auth set / orchard auth set --gitea)")
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

        Log.info("image", "booting scratch VM")
        try await tart.run(name: tmp)
        let ip = try await tart.ip(of: tmp, timeout: 300)
        Log.info("image", "scratch VM at \(ip); injecting runner agent + tweaks")

        let result = try await ssh.exec(vm: tmp, user: options.user, ip: ip, script: script, timeout: 900)
        guard result.succeeded else {
            throw ImageError.provisioningFailed(String(result.stderr.prefix(500)))
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

    public enum ImageError: LocalizedError {
        case provisioningFailed(String)
        case noCredentials(String)

        public var errorDescription: String? {
            switch self {
            case .provisioningFailed(let why): return "image provisioning failed: \(why)"
            case .noCredentials(let why): return "no platform credentials: \(why)"
            }
        }
    }
}
