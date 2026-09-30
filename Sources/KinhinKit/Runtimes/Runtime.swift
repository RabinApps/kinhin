import Foundation

// MARK: - Runtime identity

/// Where runner workloads execute. Stage 1 ships only `.tart`; the Docker
/// and Host implementations land in stages 3–4 of the runtime design
/// (docs/runtime-abstraction-design.md).
public enum RuntimeID: String, Codable, Sendable, CaseIterable {
    case tart
    /// Apple's `container` CLI (github.com/apple/container): Linux runner
    /// workloads in per-container microVMs on Apple silicon. An alternative
    /// to the Docker runtime for Linux jobs — no daemon, no shared VM.
    case appleContainer
    case docker
    case host
}

/// Health of a runtime's prerequisites — same shape as `TartHealth`, so the
/// checklist renders it with existing machinery.
public enum RuntimeHealth: Equatable, Sendable {
    case ready
    case missing(tool: String, fix: String)
    case broken(String)

    public var isReady: Bool {
        if case .ready = self { return true }
        return false
    }
}

/// The routing context a runtime needs to provision and register a runner
/// for one repo. Stage 1 carries the current config-driven values; stage 2
/// generalizes it to per-repo routes from the `runtimes:` config section.
public struct RepoRoute: Sendable, Equatable {
    public let repo: String
    public let image: String
    public let ephemeral: Bool
    let bootTimeout: Int
    /// Opt-in (`toolchains.share_cache`): share the host toolchain cache
    /// into every runner VM of this route via virtiofs, so per-job installs
    /// (`npm ci`, `mise install`, `fvm install`, `dotnet restore`) hit warm
    /// cache. Best-effort — see `ToolchainCacheMount`.
    let cacheMount: Bool

    public init(repo: String, image: String, ephemeral: Bool, bootTimeout: Int, cacheMount: Bool = false) {
        self.repo = repo
        self.image = image
        self.ephemeral = ephemeral
        self.bootTimeout = bootTimeout
        self.cacheMount = cacheMount
    }

    /// The route implied by today's single-fleet config.
    public static func from(config: KinhinConfig) -> RepoRoute {
        RepoRoute(
            repo: config.repo,
            image: config.image,
            ephemeral: config.vm.ephemeral,
            bootTimeout: config.vmBootTimeout,
            cacheMount: config.toolchains?.shareCache ?? false
        )
    }
}

// MARK: - Protocol

/// The execution runtime behind the fleet: how workloads are provisioned,
/// how the runner agent is injected, how job completion is watched, and how
/// instances are torn down. Mirrors the engine's lifecycle seams one-to-one
/// so the engine stays runtime-agnostic. Forge (who hands us jobs) and
/// Runtime (where jobs execute) are orthogonal axes.
public protocol Runtime: Sendable {
    var id: RuntimeID { get }

    /// Prerequisite probe (checklist/doctor).
    func health() async -> RuntimeHealth

    /// Provision a fresh runner instance with the given id (clone + boot for
    /// VM runtimes; container start; nothing for host). Must be idempotent
    /// for an id that already exists (recovery path).
    func provision(id: String, route: RepoRoute) async throws

    /// Wait for a provisioned instance to become ready for registration.
    /// Runtimes reachable over a network return the address the registration
    /// transport dials (Tart: the VM's IP for SSH); exec-transport runtimes
    /// (apple container, docker, host) return nil — registration goes
    /// through `execRegistration` with no address.
    func awaitReady(id: String, timeout: TimeInterval) async throws -> String?

    /// Execute the registration script inside the instance. Runtimes whose
    /// `awaitReady` returned an address dial it (SSH); the rest exec locally
    /// inside the instance (container/docker exec).
    func execRegistration(_ id: String, ip: String?, _ script: String, timeout: TimeInterval) async throws
        -> ShellResult

    /// Ids of this runtime's existing instances — the recovery/adopt path
    /// enumerates every configured runtime through this (no per-runtime
    /// branch in the engine). Throws when the runtime can't be asked: a
    /// failed listing must never read as "no instances".
    func existingInstanceIDs() async throws -> [String]

    /// The bootstrap script that turns the provisioned instance into N
    /// registered runners. The engine executes it inside the instance.
    /// `token` is the shared registration token; `runnerTokens` holds the
    /// per-runner credentials of `perRunner` forges (GitLab), keyed by runner
    /// name. `labels` overrides the forge's default label set for the GitHub
    /// branch — the pool's labels in mixed fleets.
    func registrationScript(
        forge: Forge, token: String, runnerTokens: [String: String], name: String,
        runnerCount: Int, route: RepoRoute, labels: [String]?
    ) async throws -> String

    /// Stop and remove the instance. Must be idempotent.
    func teardown(id: String) async
}

extension Runtime {
    /// Shared-token registration (every forge but GitLab).
    func registrationScript(
        forge: Forge, token: String, name: String,
        runnerCount: Int, route: RepoRoute, labels: [String]?
    ) async throws -> String {
        try await registrationScript(
            forge: forge, token: token, runnerTokens: [:], name: name, runnerCount: runnerCount, route: route,
            labels: labels)
    }
}

// MARK: - Tart implementation

/// The original runtime: Tart macOS VMs. Wraps the exact calls the engine
/// made directly before the refactor — behavior-preserving by construction.
struct TartRuntime: Runtime {
    let id: RuntimeID = .tart
    let tart: TartControlling
    let ssh: SSHExecuting
    let bootTimeout: @Sendable () -> Int
    /// The resolved managed-toolchain selection (cache envs come from here
    /// when `share_cache` mounts the host cache into runner VMs).
    let toolchainsConfig: @Sendable () -> KinhinConfig.ToolchainsConfig?

    /// Cache envs to export in registration scripts when the route mounts
    /// the shared cache. Computed once per script request from live config.
    var cachedToolchainSelection: ManagedToolchainSelection? {
        guard let config = toolchainsConfig() else { return nil }
        return ToolchainCatalog.selection(from: config)
    }

    init(
        tart: TartControlling, bootTimeout: @escaping @Sendable () -> Int, ssh: SSHExecuting = SSHExecutor(),
        toolchainsConfig: @escaping @Sendable () -> KinhinConfig.ToolchainsConfig? = { nil }
    ) {
        self.tart = tart
        self.bootTimeout = bootTimeout
        self.ssh = ssh
        self.toolchainsConfig = toolchainsConfig
    }

    func health() async -> RuntimeHealth {
        let probe = TartHealthProbe()
        let health = await probe.check()
        switch health {
        case .healthy:
            return .ready
        case .missing:
            return .missing(
                tool: "tart", fix: TartHealthProbe.installCommand)
        case .killedOnLaunch:
            return .missing(tool: "tart (notarization rollback)", fix: "roll back to the notarized Cirrus Labs build")
        case .broken(let why):
            return .broken(why)
        }
    }

    func provision(id: String, route: RepoRoute) async throws {
        // A failed list must not read as "no VMs": cloning over an existing
        // one would fail later with a far less useful error.
        let existing = try await tart.list()
        if existing.contains(where: { $0.name == id }) {
            Log.info(id, "VM already exists; reusing (recovery)")
            return
        }
        Log.info(id, "cloning from \(route.image)")
        try await tart.clone(source: route.image, to: id)
        let mounts = route.cacheMount ? [ToolchainCacheMount.guestPath] : []
        try await tart.run(name: id, mounts: mounts)
    }

    func awaitReady(id: String, timeout: TimeInterval) async throws -> String? {
        try await tart.ip(of: id, timeout: timeout)
    }

    func execRegistration(_ id: String, ip: String?, _ script: String, timeout: TimeInterval) async throws
        -> ShellResult
    {
        guard let ip, !ip.isEmpty else {
            throw TartError.ipNotFound(vm: id)
        }
        return try await ssh.exec(vm: id, user: "admin", ip: ip, script: script, timeout: timeout)
    }

    func existingInstanceIDs() async throws -> [String] {
        try await tart.list().map(\.name)
    }

    func registrationScript(
        forge: Forge, token: String, runnerTokens: [String: String], name: String,
        runnerCount: Int, route: RepoRoute, labels: [String]?
    ) async throws -> String {
        // Opt-in shared cache: point the selected ecosystems' caches at the
        // mounted host share so per-job installs reuse warm downloads. The
        // env prefix is prepended to whichever registration script the forge
        // produces; exports are guarded no-ops when the share is absent.
        let cachePrefix = RunnerBootstrap.cachePrefix(
            mounted: route.cacheMount, selection: cachedToolchainSelection, mountPath: ToolchainCacheMount.guestPath)
        switch forge.credentials.forge {
        case .github:
            return cachePrefix
                + RunnerBootstrap.registrationScript(
                    configureURL: forge.registrationURL(),
                    token: token,
                    labels: labels ?? forge.labels,
                    ephemeral: route.ephemeral,
                    name: name,
                    runnerCount: runnerCount
                )
        case .gitea, .forgejo:
            // Forgejo shares Gitea's runner binary and registration flow.
            return cachePrefix
                + RunnerBootstrap.giteaRegistrationScript(
                    instance: forge.registrationURL(),
                    token: token,
                    labels: forge.labels,
                    name: name,
                    runnerCount: runnerCount
                )
        case .gitlab:
            return cachePrefix
                + RunnerBootstrap.gitlabRegistrationScript(
                    instance: forge.registrationURL(),
                    runners: try RunnerBootstrap.gitlabRunners(
                        name: name, runnerCount: runnerCount, tokens: runnerTokens),
                    binary: "\"$HOME/gitlab-runner/gitlab-runner\"",
                    baseDir: "\"$HOME/gitlab-runner\""
                )
        case .buildkite:
            return cachePrefix
                + RunnerBootstrap.buildkiteRegistrationScript(
                    token: token,
                    tags: RunnerBootstrap.buildkiteTags(accountLabels: forge.labels, poolLabels: labels),
                    runnerNames: FleetEngine.runnerNames(for: name, count: runnerCount),
                    ephemeral: route.ephemeral,
                    binary: "\"$HOME/buildkite-agent/buildkite-agent\"",
                    baseDir: "\"$HOME/buildkite-agent\""
                )
        }
    }

    func teardown(id: String) async {
        // Existence check makes teardown genuinely idempotent (double deletes
        // from racing lifecycle paths must not error or double-charge).
        do {
            guard try await tart.list().contains(where: { $0.name == id }) else { return }
        } catch {
            // Unknown state: still attempt the teardown below.
            Log.warn(id, "could not list VMs before teardown: \(error.localizedDescription)")
        }
        await bestEffortAsync(id, "stopping VM") { try await tart.stop(name: id) }
        await bestEffortAsync(id, "deleting VM") { try await tart.delete(name: id) }
    }
}
