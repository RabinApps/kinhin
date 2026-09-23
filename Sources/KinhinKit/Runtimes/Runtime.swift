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
    public let bootTimeout: Int
    /// Opt-in (`toolchains.share_cache`): share the host toolchain cache
    /// into every runner VM of this route via virtiofs, so per-job installs
    /// (`npm ci`, `mise install`, `fvm install`, `dotnet restore`) hit warm
    /// cache. Best-effort — see `ToolchainCacheMount`.
    public let cacheMount: Bool

    public init(repo: String, image: String, ephemeral: Bool, bootTimeout: Int, cacheMount: Bool = false) {
        self.repo = repo
        self.image = image
        self.ephemeral = ephemeral
        self.bootTimeout = bootTimeout
        self.cacheMount = cacheMount
    }

    /// The route implied by today's single-fleet config.
    public static func from(config: kinhinConfig) -> RepoRoute {
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
    func execRegistration(_ id: String, ip: String?, _ script: String, timeout: TimeInterval) async throws -> ShellResult

    /// Ids of this runtime's existing instances — the recovery/adopt path
    /// enumerates every configured runtime through this (no per-runtime
    /// branch in the engine).
    func existingInstanceIDs() async -> [String]

    /// The bootstrap script that turns the provisioned instance into N
    /// registered runners (GitHub/Gitea scripts today). The engine executes
    /// it inside the instance. `labels` overrides the forge's default label
    /// set for the GitHub branch — the pool's labels in mixed fleets.
    func registrationScript(forge: Forge, token: String, name: String,
                            runnerCount: Int, route: RepoRoute, labels: [String]?) async throws -> String

    /// Watch the instance's runners until the ephemeral exit condition holds
    /// (all runners gone, or idle grace for runtimes without deregistration).
    /// Returns normally when the instance is ready to be torn down.
    func watchExit(id: String, forge: Forge, runnerCount: Int, route: RepoRoute) async throws

    /// Stop and remove the instance. Must be idempotent.
    func teardown(id: String) async
}

// MARK: - Tart implementation

/// The original runtime: Tart macOS VMs. Wraps the exact calls the engine
/// made directly before the refactor — behavior-preserving by construction.
public struct TartRuntime: Runtime {
    public let id: RuntimeID = .tart
    let tart: TartControlling
    let ssh: SSHExecuting
    let bootTimeout: @Sendable () -> Int
    /// The resolved managed-toolchain selection (cache envs come from here
    /// when `share_cache` mounts the host cache into runner VMs).
    let toolchainsConfig: @Sendable () -> kinhinConfig.ToolchainsConfig?

    /// Cache envs to export in registration scripts when the route mounts
    /// the shared cache. Computed once per script request from live config.
    var cachedToolchainSelection: ManagedToolchainSelection? {
        guard let config = toolchainsConfig() else { return nil }
        return ToolchainCatalog.selection(from: config)
    }

    public init(tart: TartControlling, bootTimeout: @escaping @Sendable () -> Int, ssh: SSHExecuting = SSHExecutor(), toolchainsConfig: @escaping @Sendable () -> kinhinConfig.ToolchainsConfig? = { nil }) {
        self.tart = tart
        self.bootTimeout = bootTimeout
        self.ssh = ssh
        self.toolchainsConfig = toolchainsConfig
    }

    public func health() async -> RuntimeHealth {
        let probe = TartHealthProbe()
        let health = await probe.check()
        switch health {
        case .healthy:
            return .ready
        case .missing:
            return .missing(tool: "tart", fix: "brew tap openai/tools && brew trust openai/tools && brew install openai/tools/tart")
        case .killedOnLaunch:
            return .missing(tool: "tart (notarization rollback)", fix: "roll back to the notarized Cirrus Labs build")
        case .broken(let why):
            return .broken(why)
        }
    }

    public func provision(id: String, route: RepoRoute) async throws {
        let existing = (try? await tart.list()) ?? []
        if existing.contains(where: { $0.name == id }) {
            Log.info(id, "VM already exists; reusing (recovery)")
            return
        }
        Log.info(id, "cloning from \(route.image)")
        try await tart.clone(source: route.image, to: id)
        let mounts = route.cacheMount ? [ToolchainCacheMount.guestPath] : []
        try await tart.run(name: id, mounts: mounts)
    }

    public func awaitReady(id: String, timeout: TimeInterval) async throws -> String? {
        try await tart.ip(of: id, timeout: timeout)
    }

    public func execRegistration(_ id: String, ip: String?, _ script: String, timeout: TimeInterval) async throws -> ShellResult {
        guard let ip, !ip.isEmpty else {
            throw TartError.ipNotFound(vm: id)
        }
        return try await ssh.exec(vm: id, user: "admin", ip: ip, script: script, timeout: timeout)
    }

    public func existingInstanceIDs() async -> [String] {
        (try? await tart.list())?.map(\.name) ?? []
    }

    public func registrationScript(forge: Forge, token: String, name: String,
                                   runnerCount: Int, route: RepoRoute, labels: [String]?) async throws -> String {
        // Opt-in shared cache: point the selected ecosystems' caches at the
        // mounted host share so per-job installs reuse warm downloads. The
        // env prefix is prepended to whichever registration script the forge
        // produces; exports are guarded no-ops when the share is absent.
        let cachePrefix: String
        if route.cacheMount, let selection = cachedToolchainSelection {
            cachePrefix = RunnerBootstrap.cacheEnvExports(
                cacheEnvs: selection.cacheEnvs,
                mountPath: ToolchainCacheMount.guestPath
            ) + "\n\n"
        } else {
            cachePrefix = ""
        }
        switch forge.credentials {
        case .github:
            return cachePrefix + RunnerBootstrap.registrationScript(
                configureURL: forge.registrationURL(),
                token: token,
                labels: labels ?? forge.labels,
                ephemeral: route.ephemeral,
                name: name,
                runnerCount: runnerCount
            )
        case .gitea:
            return cachePrefix + RunnerBootstrap.giteaRegistrationScript(
                instance: forge.registrationURL(),
                token: token,
                labels: forge.labels,
                name: name,
                runnerCount: runnerCount
            )
        }
    }

    /// The engine's watches are forge-specific today (GitHub deregistration
    /// semantics vs Gitea idle-grace); the runtime exposes them as the
    /// exit-wait, selected by forge id. Stage 1 keeps the engine's existing
    /// watch methods authoritative — this hook exists for symmetry and for
    /// non-VM runtimes to override later.
    public func watchExit(id: String, forge: Forge, runnerCount: Int, route: RepoRoute) async throws {
        // Engine-owned watch (needs the record store + statusBox); nothing to
        // do at the runtime layer for Tart. Non-VM runtimes implement their
        // own container/host polling here in stages 3–4.
    }

    public func teardown(id: String) async {
        // Existence check makes teardown genuinely idempotent (double deletes
        // from racing lifecycle paths must not error or double-charge).
        let existing = (try? await tart.list()) ?? []
        guard existing.contains(where: { $0.name == id }) else { return }
        try? await tart.stop(name: id)
        try? await tart.delete(name: id)
    }
}
