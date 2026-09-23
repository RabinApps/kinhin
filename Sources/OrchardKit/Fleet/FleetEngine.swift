import Foundation
import Yams

public final class FleetEngine {
    let config: OrchardConfig
    let tart: TartControlling
    let store: FleetStore
    let ssh: SSHExecuting
    let registrationTokens: RegistrationTokenCache
    let statusBox: FleetStatusBox
    let capacity: Capacity.Plan
    let credentialsLock = NSLock()
    var credentials: GitHubCredentials
    var githubFactory: GitHubClientFactory
    /// Guarded by credentialsLock; only mutated from the engine's own serial
    /// context (start/replaceCredentials), never mid-reconcile.
    var githubInstance: GitHubServing
    /// Forge instances by platform string ("github", "gitea"), guarded by
    /// forgesLock. The v1 wiring carries exactly the GitHub forge.
    let forgesLock = NSLock()
    var forgesByPlatform: [String: Forge] = [:]

    /// The API client in use. Swapped atomically by replaceCredentials.
    public var github: GitHubServing { credentialsLock.withLock { githubInstance } }

    /// Forge instances serving this fleet, keyed by platform string.
    public var forges: [String: Forge] { forgesLock.withLock { forgesByPlatform } }

    var reconcileTask: Task<Void, Never>?
    var lifecycleTasks: [String: Task<Void, Never>] = [:]
    let lifecycleLock = NSLock()

    public private(set) var paused = false
    var running = false
    let stateLock = NSLock()

    /// The execution runtime backing this fleet. With `container:` config
    /// present this is the Apple-container runtime (Linux microVMs); else
    /// Tart. The runtime is a fixed property of the engine instance (config
    /// changes restart the engine via the daemon).
    let runtime: any Runtime
    /// Non-nil when the fleet can run on Apple containers (mixed fleets use
    /// both runtimes, selected per record by the routing model).
    let containerRuntime: AppleContainerRuntime?
    /// Routing model: label pools + per-repo/per-workflow routes. Built from
    /// the `runtimes:` config (nil → single default pool, legacy behavior).
    /// Reloaded live by applyReloaded(config:) — guarded by routingLock, so
    /// a running fleet picks up route changes without a restart.
    var routing: RuntimeConfigModel
    var capsByRuntime: [RuntimeID: Int]
    let routingLock = NSLock()
    /// The Tart runtime instance (always available; mixed fleets select it
    /// per record while container-routed records use containerRuntime).
    let tartRuntime: TartRuntime
    /// Daily host-cache sweep task (started/stopped with the engine).
    var cachePruneTask: Task<Void, Never>?

    public init(config: OrchardConfig, github: GitHubServing, tart: TartControlling, store: FleetStore, ssh: SSHExecuting, host: HostResources, containerShell: ShellRunning? = nil) {
        let credentials = GitHubCredentials(token: "", scope: config.repo)
        self.credentials = credentials
        self.githubFactory = GitHubClientFactory { _ in github }
        self.githubInstance = github
        self.forgesByPlatform = ["github": GitHubForge(credentials: .github(token: credentials.token, scope: credentials.scope), labels: config.labels, client: github)]
        var appleRuntime: AppleContainerRuntime?
        if let containerConfig = config.container {
            let instance = AppleContainerRuntime(
                shell: containerShell ?? Shell(),
                image: containerConfig.image,
                cpus: containerConfig.cpus,
                memoryGB: containerConfig.memoryGB
            )
            appleRuntime = instance
            self.runtime = instance
        } else {
            self.runtime = TartRuntime(tart: tart, bootTimeout: { [config] in config.vmBootTimeout }, toolchainsConfig: { [config] in config.toolchains })
        }
        self.containerRuntime = appleRuntime
        self.config = config
        self.tart = tart
        self.store = store
        self.ssh = ssh
        self.registrationTokens = RegistrationTokenCache(ttl: TimeInterval(config.tokenTTL))
        self.statusBox = FleetStatusBox()
        self.capacity = Capacity.plan(
            host: host,
            vmCPU: config.container?.cpus ?? config.vm.cpuCount,
            vmMemoryGB: config.container?.memoryGB ?? config.vm.memoryGB,
            reservedCPU: config.reserve.cpu,
            reservedMemoryGB: config.reserve.memoryGB,
            diskPerVMGB: 0,
            userMax: config.maxRunners
        )
        self.tartRuntime = TartRuntime(tart: tart, bootTimeout: { [config] in config.vmBootTimeout }, toolchainsConfig: { [config] in config.toolchains })
        self.routing = RuntimeConfigModel(
            config: config.runtimes,
            fleetLabels: config.labels,
            containerLabels: config.container?.labels,
            containerConfigured: config.container != nil
        )
        if config.runtimes != nil, config.container != nil {
            // Mixed fleet: partition the usable host budget between runtimes
            // by the configured weights (deterministic, no overcommit).
            let partition = RuntimeCapacity.partition(
                hostUsableCPU: max(0, host.logicalCores - config.reserve.cpu),
                hostUsableMemoryGB: max(0, host.memoryGB - config.reserve.memoryGB),
                weights: config.runtimes?.budget ?? [:],
                defaultRuntime: RuntimeID(rawValue: config.runtimes?.defaultRuntime ?? "tart") ?? .tart,
                shape: { id in
                    id == .appleContainer
                        ? (config.container?.cpus ?? 4, config.container?.memoryGB ?? 8)
                        : (config.vm.cpuCount, config.vm.memoryGB)
                }
            )
            self.capsByRuntime = partition.caps
        } else {
            // Single-pool fleets (legacy tart-only and container-only) keep
            // the fleet cap semantics and the legacy status shape (nil
            // capacityByRuntime).
            self.capsByRuntime = [:]
        }
    }

    /// Convenience initializer matching the production wiring: a client
    /// factory keyed off the credentials (live by default; injectable in
    /// tests to observe credential swaps).
    public convenience init(config: OrchardConfig, pat: String, tart: TartControlling, store: FleetStore, ssh: SSHExecuting, host: HostResources, githubFactory: GitHubClientFactory = .live) {
        let credentials = GitHubCredentials(token: pat, scope: config.repo)
        self.init(
            config: config,
            github: githubFactory.make(credentials),
            tart: tart,
            store: store,
            ssh: ssh,
            host: host
        )
        self.credentials = credentials
        self.githubFactory = githubFactory
        self.forgesByPlatform = ["github": GitHubForge(credentials: .github(token: credentials.token, scope: credentials.scope), labels: config.labels, client: github)]
        // NOTE: `runtime` was initialized in the designated init; convenience
        // inits cannot reassign let properties.
    }

    // MARK: - Control

    public func start() async {
        let alreadyRunning = stateLock.withLock { () -> Bool in
            let was = running
            running = true
            return was
        }
        guard !alreadyRunning else { return }

        // Verify the PAT can manage runners for the scope BEFORE spawning
        // anything — a forbidden org token otherwise surfaces as per-VM
        // registration failures (and deleted VMs) instead of a clear answer.
        // Failure keeps the engine stopped and surfaced via lastError.
        let verification = await OrgPermissionProbe.verify(github: github, scope: config.repo)
        guard verification.ok else {
            Log.error("engine", "startup blocked: \(verification.message)")
            await statusBox.modify {
                $0.running = false
                $0.lastError = verification.message
            }
            return
        }

        Log.info("engine", "starting fleet engine for \(config.repo) (capacity cap: \(capacity.maxConcurrent))")
        await attachGiteaForgeIfNeeded()
        await recoverIfNeeded()
        startCachePruneSweepIfNeeded()
        let task = Task { [weak self] () -> Void in
            guard let self else { return }
            await self.reconcileLoop()
        }
        reconcileTask = task
    }

    public func stop() async {
        stateLock.withLock { running = false }
        Log.info("engine", "stopping fleet engine")
        reconcileTask?.cancel()
        reconcileTask = nil
        cachePruneTask?.cancel()
        cachePruneTask = nil
        // Mirror the flag into the status snapshot now: the reconcile pass
        // that would sync it is being cancelled, so status().running would
        // otherwise stay stale true until the engine is started again.
        await statusBox.modify { $0.running = false }
        // A token replaced while stopped must not survive into the next run
        // via the cache (minted under the old PAT's authority).
        registrationTokens.invalidate()
        await pauseAllVMs()
    }

    // MARK: - Cache maintenance

    /// Daily host-cache sweep while the fleet runs. Failures log and are
    /// ignored — pruning must never disturb scaling. The pruner's grace
    /// window keeps it from racing any in-flight download or install.
    func startCachePruneSweepIfNeeded() {
        guard ToolchainCachePolicy(from: config.toolchains).autoPrune else { return }
        cachePruneTask = Task { [weak self] () -> Void in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 86_400 * 1_000_000_000)
                guard let self else { return }
                let policy = ToolchainCachePolicy(from: self.config.toolchains)
                guard policy.autoPrune else { continue }
                ToolchainCachePruner().prune(policy: policy)
            }
        }
    }

    /// Swap in a new PAT: rebuilds the GitHub client and drops the cached
    /// registration token (minted under the old token's authority). Safe to
    /// call while running — the next reconcile/registration uses the new
    /// credentials; in-flight VMs are untouched.
    public func replaceCredentials(pat: String) async {
        let fresh = GitHubCredentials(token: pat, scope: config.repo)
        let client = githubFactory.make(fresh)
        credentialsLock.withLock {
            credentials = fresh
            githubInstance = client
        }
        forgesLock.withLock {
            forgesByPlatform["github"] = GitHubForge(credentials: .github(token: fresh.token, scope: fresh.scope), labels: config.labels, client: client)
        }
        registrationTokens.invalidate()
        Log.info("engine", "GitHub credentials replaced (scope: \(config.repo))")
    }

    /// Build the Gitea forge when the config declares one. The registration
    /// token mint doubles as the permission probe — a failure here keeps the
    /// fleet running GitHub-only with the reason in lastError (never a
    /// silently dead forge).
    func attachGiteaForgeIfNeeded() async {
        guard let giteaConfig = config.gitea else { return }
        guard forgesLock.withLock({ forgesByPlatform["gitea"] == nil }) else { return }
        guard let token = KeychainTokenStore.load(forge: .gitea) else {
            let message = "gitea configured but no access token stored — run: orchard auth set --gitea"
            Log.error("engine", message)
            await statusBox.modify { $0.lastError = message }
            return
        }
        do {
            let credentials = GiteaCredentials(token: token, scope: giteaConfig.scope, instance: giteaConfig.instance)
            let forge = try await GiteaForge.make(
                credentials: credentials,
                labels: giteaConfig.labels ?? ["macos:host"],
                demandFloor: config.minRunners
            )
            forgesLock.withLock { forgesByPlatform["gitea"] = forge }
            Log.info("engine", "gitea forge attached (\(giteaConfig.scope) @ \(giteaConfig.instance))")
        } catch {
            let message = (error as? LocalizedError)?.errorDescription ?? "\(error)"
            Log.error("engine", "gitea forge unavailable: \(message)")
            await statusBox.modify { $0.lastError = "gitea: \(message)" }
        }
    }

    /// Swap the Gitea access token live: rebuilds the forge (re-minting its
    /// registration token) or attaches one for the first time.
    public func replaceGiteaToken(_ token: String) async {
        guard let giteaConfig = config.gitea else {
            Log.warn("engine", "gitea token replaced but no gitea forge is configured")
            return
        }
        do {
            let credentials = GiteaCredentials(token: token, scope: giteaConfig.scope, instance: giteaConfig.instance)
            let forge = try await GiteaForge.make(
                credentials: credentials,
                labels: giteaConfig.labels ?? ["macos:host"],
                demandFloor: config.minRunners
            )
            forgesLock.withLock { forgesByPlatform["gitea"] = forge }
            Log.info("engine", "gitea credentials replaced (\(giteaConfig.scope) @ \(giteaConfig.instance))")
        } catch {
            let message = (error as? LocalizedError)?.errorDescription ?? "\(error)"
            Log.error("engine", "gitea token replacement failed: \(message)")
            await statusBox.modify { $0.lastError = "gitea: \(message)" }
        }
    }

    public func setPaused(_ value: Bool) async {
        stateLock.withLock { paused = value }
        Log.info("engine", value ? "paused (no new VMs will be started)" : "resumed")
        await statusBox.modify { $0.paused = value }
    }

    // MARK: - Live config reload

    /// Swap in routing state from a freshly loaded config: the routing model
    /// (pools + routes), the capacity partition, and the pool set. Callable
    /// while running — the next reconcile demand-buckets and spawns against
    /// the new shapes without a restart. Existing records keep their assigned
    /// runtime until they finish (teardown is per-record), so no instance is
    /// disrupted mid-job.
    ///
    /// Scope: routing only. A container-image change or a runtime's shape
    /// lives in the runtime instance (fixed per engine) and still needs a
    /// daemon restart.
    public func applyReloaded(config newConfig: OrchardConfig, host: HostResources) {
        let model = RuntimeConfigModel(
            config: newConfig.runtimes,
            fleetLabels: newConfig.labels,
            containerLabels: newConfig.container?.labels,
            containerConfigured: newConfig.container != nil
        )
        var caps: [RuntimeID: Int] = [:]
        if newConfig.runtimes != nil, newConfig.container != nil {
            // Same partition the init computes for a mixed fleet.
            let partition = RuntimeCapacity.partition(
                hostUsableCPU: max(0, host.logicalCores - newConfig.reserve.cpu),
                hostUsableMemoryGB: max(0, host.memoryGB - newConfig.reserve.memoryGB),
                weights: newConfig.runtimes?.budget ?? [:],
                defaultRuntime: RuntimeID(rawValue: newConfig.runtimes?.defaultRuntime ?? "tart") ?? .tart,
                shape: { id in
                    id == .appleContainer
                        ? (newConfig.container?.cpus ?? 4, newConfig.container?.memoryGB ?? 8)
                        : (newConfig.vm.cpuCount, newConfig.vm.memoryGB)
                }
            )
            caps = partition.caps
        }
        routingLock.withLock {
            routing = model
            capsByRuntime = caps
        }
        // Fleet label edits must reach the forge's demand query too —
        // queuedJobs(matching:) filters by the forge's label set.
        forgesLock.withLock {
            if let githubForge = forgesByPlatform["github"] as? GitHubForge {
                forgesByPlatform["github"] = GitHubForge(
                    credentials: githubForge.credentials,
                    labels: newConfig.labels,
                    client: githubForge.client
                )
            }
        }
        let poolNames = model.pools.keys.map(\.rawValue).sorted().joined(separator: ", ")
        let capNote = caps.isEmpty ? "fleet cap" : "partitioned caps"
        Log.info("engine", "routing reloaded (pools: \(poolNames), \(capNote))")
    }

    public func status() async -> FleetStatus {
        var status = await statusBox.get()
        // Records live in the store; derive them on read so snapshots can
        // never go stale relative to store mutations.
        status.records = store.all
        status.runtime = runtime.id.rawValue
        if !capsByRuntime.isEmpty {
            var caps: [String: String] = [:]
            for (id, cap) in capsByRuntime {
                caps[id.rawValue] = String(cap)
            }
            status.capacityByRuntime = caps
        }
        return status
    }

    /// Manually delete one VM (from the UI). Reconcile will scale back up if
    /// demand still exists; the user should pause first to hold the fleet down.
    public func deleteVM(id: String) async {
        Log.info("engine", "manual delete of \(id)")
        await runTelemetryIfPossible(id)
        await deleteVMRecord(id: id, reason: "manual delete")
    }

}
