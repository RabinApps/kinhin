import Foundation
import Yams

// MARK: - Routing state

/// The live routing model and its per-runtime caps, swapped together on reload.
struct RoutingState {
    var model: RuntimeConfigModel
    var caps: [RuntimeID: Int]
}

/// The legacy GitHub account's credentials and the client built from them.
struct GitHubAuth {
    var credentials: GitHubCredentials
    var client: GitHubServing
}

/// Attached forges by platform or account name ("github", "gitea", an
/// `accounts:` name), plus the bookkeeping that changes with them.
struct ForgeState {
    var byPlatform: [String: Forge] = [:]
    /// Registration-token caches for explicit accounts; the legacy GitHub
    /// account uses the engine's `registrationTokens`.
    var accountRegistrationTokens: [String: RegistrationTokenCache] = [:]
    /// Retry schedule for forges that failed at startup (FleetForgeRetry.swift).
    var retry = ForgeRetryState()
}

/// The engine's serving flags, read by the reconcile loop and forge retry.
struct RunState {
    var running = false
    var paused = false
}

// MARK: - Engine

public final class FleetEngine {
    let config: KinhinConfig
    let tart: TartControlling
    let store: FleetStore
    let ssh: SSHExecuting
    let registrationTokens: RegistrationTokenCache
    let statusBox: FleetStatusBox
    let capacity: Capacity.Plan
    var githubFactory: GitHubClientFactory
    /// The legacy GitHub account's credentials and client, swapped together
    /// by replaceCredentials.
    let githubAuth: Mutex<GitHubAuth>
    /// Attached forges, per-account registration-token caches and the
    /// detached-forge retry schedule.
    let forgeState: Mutex<ForgeState>
    /// Resolves an account's token (forge, account name). Keychain in
    /// production; tests inject their own.
    var tokenLoader: @Sendable (ForgeID, String) throws -> String? = {
        try KeychainTokenStore.load(forge: $0, name: $1)
    }
    /// Host snapshot for the pre-spawn disk guard. Defaults to the static
    /// construction-time host value (hermetic — tests inject their own);
    /// production wiring swaps in a live statfs probe via `useLiveDiskProbe`.
    var hostProbe: @Sendable () -> HostResources = { ResourceProbe().snapshot() }
    /// Opts the disk guard into live probing (production wiring only; tests
    /// keep the hermetic construction snapshot or set their own probe).
    public func useLiveDiskProbe() { hostProbe = { ResourceProbe().snapshot() } }

    /// The API client in use. Swapped atomically by replaceCredentials.
    public var github: GitHubServing { githubAuth.withLock { $0.client } }

    /// Forge instances serving this fleet, keyed by platform string.
    public var forges: [String: Forge] { forgeState.withLock { $0.byPlatform } }

    var reconcileTask: Task<Void, Never>?
    /// One lifecycle task per VM id (removed by the task itself on finish).
    let lifecycleTasks = Mutex<[String: Task<Void, Never>]>([:])
    /// How long `detachKeepingInstances()` waits for cancelled lifecycle
    /// tasks before handing the fleet over anyway. Tests shorten it.
    var lifecycleDrainTimeout: Duration = .seconds(15)

    /// Whether the fleet is serving and whether it is paused.
    let runState = Mutex(RunState())
    public var paused: Bool { runState.withLock { $0.paused } }
    var running: Bool { runState.withLock { $0.running } }

    /// The execution runtime backing this fleet. With `container:` config
    /// present this is the Apple-container runtime (Linux microVMs); else
    /// Tart. The runtime is a fixed property of the engine instance (config
    /// changes restart the engine via the daemon).
    let runtime: any Runtime
    /// Non-nil when the fleet can run on Apple containers (mixed fleets use
    /// both runtimes, selected per record by the routing model).
    let containerRuntime: AppleContainerRuntime?
    /// Non-nil when the fleet can run Docker slots (Linux containers in the
    /// provider's shared VM; selected per record by the routing model).
    let dockerRuntime: DockerRuntime?
    /// Non-nil when the config routes any repo/workflow to host execution
    /// (consent-gated; see `ConfigLoader`'s host validation).
    let hostRuntime: HostRuntime?
    /// Routing model: label pools + per-repo/per-workflow routes. Built from
    /// the `runtimes:` config (nil → single default pool, legacy behavior).
    /// Reloaded live by applyReloaded(config:), so a running fleet picks up
    /// route changes without a restart. Read through `routing` and
    /// `capsByRuntime`, which take the lock.
    let routingState: Mutex<RoutingState>
    var routing: RuntimeConfigModel { routingState.withLock { $0.model } }
    var capsByRuntime: [RuntimeID: Int] { routingState.withLock { $0.caps } }
    /// The Tart runtime instance (always available; mixed fleets select it
    /// per record while container-routed records use containerRuntime).
    let tartRuntime: TartRuntime
    /// Every runtime this fleet can execute on, keyed by id. Lifecycle and
    /// recovery dispatch through this map — no per-runtime branches in the
    /// engine. (Future hosted runtimes join here when configured.)
    let runtimesByRuntime: [RuntimeID: any Runtime]
    /// Daily host-cache sweep task (started/stopped with the engine).
    var cachePruneTask: Task<Void, Never>?

    public init(
        config: KinhinConfig, github: GitHubServing, tart: TartControlling, store: FleetStore, ssh: SSHExecuting,
        host: HostResources, containerShell: ShellRunning? = nil
    ) {
        let credentials = GitHubCredentials(token: "", scope: config.repo)
        self.githubFactory = GitHubClientFactory { _ in github }
        self.githubAuth = Mutex(GitHubAuth(credentials: credentials, client: github))
        self.forgeState = Mutex(
            ForgeState(byPlatform: Self.initialForges(config: config, credentials: credentials, client: github)))
        let tartInstance = TartRuntime(
            tart: tart, bootTimeout: { [config] in config.vmBootTimeout }, ssh: ssh,
            toolchainsConfig: { [config] in config.toolchains })
        var appleRuntime: AppleContainerRuntime?
        if let containerConfig = config.container {
            appleRuntime = AppleContainerRuntime(
                shell: containerShell ?? Shell(),
                image: containerConfig.image,
                cpus: containerConfig.cpus,
                memoryGB: containerConfig.memoryGB,
                toolchainsConfig: { [config] in config.toolchains }
            )
        }
        var dockerInstance: DockerRuntime?
        if let dockerConfig = config.docker {
            dockerInstance = DockerRuntime(
                shell: containerShell ?? Shell(),
                image: dockerConfig.image,
                cpus: dockerConfig.cpus,
                memoryGB: dockerConfig.memoryGB,
                platform: dockerConfig.platform,
                toolchainsConfig: { [config] in config.toolchains }
            )
        }
        var hostInstance: HostRuntime?
        if config.hostRoutesConfigured {
            hostInstance = HostRuntime(shell: containerShell ?? Shell())
        }
        // The fleet's primary runtime (single-pool fleets and the legacy
        // fleet-cap shape): containers, else Docker slots, else tart — the
        // established precedence with Docker as the new Linux fallback.
        if let appleRuntime {
            self.runtime = appleRuntime
        } else if let dockerInstance {
            self.runtime = dockerInstance
        } else {
            self.runtime = tartInstance
        }
        self.containerRuntime = appleRuntime
        self.dockerRuntime = dockerInstance
        self.tartRuntime = tartInstance
        self.hostRuntime = hostInstance
        var runtimeMap: [RuntimeID: any Runtime] = [.tart: tartInstance]
        if let appleRuntime {
            runtimeMap[.appleContainer] = appleRuntime
        }
        if let dockerInstance {
            runtimeMap[.docker] = dockerInstance
        }
        if let hostInstance {
            runtimeMap[.host] = hostInstance
        }
        self.runtimesByRuntime = runtimeMap
        self.config = config
        self.hostProbe = { [host] in host }
        self.tart = tart
        self.store = store
        self.ssh = ssh
        self.registrationTokens = RegistrationTokenCache(ttl: TimeInterval(config.tokenTTL))
        self.statusBox = FleetStatusBox()
        // The primary runtime's per-instance disk footprint: the explicit
        // disk_gb when set, else a runtime default (50 GB tart VMs, 8 GB
        // Linux container slots, 0 for host). The same estimate feeds the
        // pre-spawn disk guard and `kinhin doctor`.
        let primaryRuntimeID =
            config.container != nil
            ? RuntimeID.appleContainer
            : config.docker != nil ? RuntimeID.docker : RuntimeID.tart
        let diskPerVM = ResourceProbe.effectiveDiskPerVMGB(diskGB: config.diskGB, runtime: primaryRuntimeID.rawValue)
        self.capacity = Capacity.plan(
            host: host,
            vmCPU: config.container?.cpus ?? config.docker?.cpus ?? config.vm.cpuCount,
            vmMemoryGB: config.container?.memoryGB ?? config.docker?.memoryGB ?? config.vm.memoryGB,
            reservedCPU: config.reserve.cpu,
            reservedMemoryGB: config.reserve.memoryGB,
            diskPerVMGB: diskPerVM,
            userMax: config.maxRunners
        )
        let routing = RuntimeConfigModel(
            config: config.runtimes,
            fleetLabels: config.labels,
            containerLabels: config.container?.labels,
            containerConfigured: config.container != nil,
            dockerConfigured: config.docker != nil,
            dockerPlatform: config.docker?.platform ?? .arm64,
            hostConfigured: config.hostRoutesConfigured
        )

        let caps: [RuntimeID: Int]
        if config.runtimes != nil, config.container != nil || config.docker != nil {
            // Mixed fleet: partition the usable host budget between runtimes
            // by the configured weights (deterministic, no overcommit).
            let partition = RuntimeCapacity.partition(
                hostUsableCPU: max(0, host.logicalCores - config.reserve.cpu),
                hostUsableMemoryGB: max(0, host.memoryGB - config.reserve.memoryGB),
                weights: config.runtimes?.budget ?? [:],
                defaultRuntime: RuntimeID(rawValue: config.runtimes?.defaultRuntime ?? "tart") ?? .tart,
                shape: { id in
                    switch id {
                    case .appleContainer:
                        return (config.container?.cpus ?? 4, config.container?.memoryGB ?? 8)
                    case .docker:
                        return (config.docker?.cpus ?? 2, config.docker?.memoryGB ?? 4)
                    case .host:
                        // Host slots cost the Mac nothing extra beyond the
                        // user's own processes (1/1 keeps the math non-zero
                        // without shrinking other pools).
                        return (1, 1)
                    default:
                        return (config.vm.cpuCount, config.vm.memoryGB)
                    }
                }
            )
            var partitioned = partition.caps
            // Docker's hard slot cap applies on top of the budget partition.
            if let dockerConfig = config.docker, let partitionCap = partitioned[.docker] {
                partitioned[.docker] = min(partitionCap, dockerConfig.maxSlots)
            }
            caps = partitioned
        } else {
            // Single-pool fleets (legacy tart-only and container-only) keep
            // the fleet cap semantics and the legacy status shape (nil
            // capacityByRuntime).
            caps = [:]
        }
        self.routingState = Mutex(RoutingState(model: routing, caps: caps))
    }

    /// The forges attached at construction. Gitea-only configs never build a
    /// GitHub forge (no token, no scope); the other forges attach in start().
    private static func initialForges(
        config: KinhinConfig, credentials: GitHubCredentials, client: GitHubServing
    ) -> [String: Forge] {
        guard config.githubEnabled else { return [:] }
        return [
            "github": GitHubForge(
                credentials: .github(token: credentials.token, scope: credentials.scope), labels: config.labels,
                client: client)
        ]
    }

    /// Convenience initializer matching the production wiring: a client
    /// factory keyed off the credentials (live by default; injectable in
    /// tests to observe credential swaps).
    public convenience init(
        config: KinhinConfig, pat: String, tart: TartControlling, store: FleetStore, ssh: SSHExecuting,
        host: HostResources, githubFactory: GitHubClientFactory = .live
    ) {
        let credentials = GitHubCredentials(token: pat, scope: config.repo)
        self.init(
            config: config,
            github: githubFactory.make(credentials),
            tart: tart,
            store: store,
            ssh: ssh,
            host: host
        )
        self.githubFactory = githubFactory
        let client = github
        githubAuth.withLock { $0.credentials = credentials }
        forgeState.withLock {
            $0.byPlatform = Self.initialForges(config: config, credentials: credentials, client: client)
        }
        // NOTE: `runtime` was initialized in the designated init; convenience
        // inits cannot reassign let properties.
    }
}
