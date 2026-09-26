import Foundation

// FleetEngine — live config reload: what a running engine can adopt in
// place (routing, caps, labels) and the hand-off when it must be rebuilt.
extension FleetEngine {
    /// Which parts of a config edit the *running* engine can adopt without
    /// a rebuild: the routing model (pools/routes/budget), the capacity
    /// partition, and the GitHub forge's label set — exactly what
    /// `applyReloaded` swaps under the locks. Everything else (bounds, poll
    /// cadence, per-VM shape, images, reserve, forge sections, toolchains)
    /// lives in the frozen `config` the engine was built with, so a change
    /// there silently does nothing until the engine is rebuilt.
    public static func restartRequired(from old: KinhinConfig, to new: KinhinConfig) -> Bool {
        var a = old
        var b = new
        a.runtimes = nil
        b.runtimes = nil
        a.labels = []
        b.labels = []
        return a != b
    }

    /// The frozen config this engine instance was built with — read live
    /// (e.g. to diff against the on-disk file before deciding between a
    /// hot reload and a rebuild).
    public var activeConfig: KinhinConfig { config }

    /// Stop scaling and cancel lifecycle work while keeping every spawned
    /// instance and its record: the replacement engine's recovery adopts
    /// them (rebooted engine: phases move back to booting where needed).
    /// Deliberately NOT `stop()` — that tears all instances down, which a
    /// config rebuild must never do.
    public func detachKeepingInstances() async {
        runState.withLock { $0.running = false }
        reconcileTask?.cancel()
        reconcileTask = nil
        cachePruneTask?.cancel()
        cachePruneTask = nil
        let tasks = lifecycleTasks.withLock { tasks -> [Task<Void, Never>] in
            defer { tasks.removeAll() }
            return Array(tasks.values)
        }
        for task in tasks { task.cancel() }
        invalidateRegistrationTokens()
        // Mirror the flag into the status snapshot (stop() does the same):
        // status().running must go false immediately, not at the next
        // reconcile pass (which is now cancelled).
        await statusBox.modify { $0.running = false }
    }

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
    public func applyReloaded(config newConfig: KinhinConfig, host: HostResources) {
        let model = RuntimeConfigModel(
            config: newConfig.runtimes,
            fleetLabels: newConfig.labels,
            containerLabels: newConfig.container?.labels,
            containerConfigured: newConfig.container != nil,
            dockerConfigured: newConfig.docker != nil,
            dockerPlatform: newConfig.docker?.platform ?? .arm64,
            hostConfigured: newConfig.hostRoutesConfigured
        )
        var caps: [RuntimeID: Int] = [:]
        if newConfig.runtimes != nil, newConfig.container != nil || newConfig.docker != nil {
            // Same partition the init computes for a mixed fleet.
            let partition = RuntimeCapacity.partition(
                hostUsableCPU: max(0, host.logicalCores - newConfig.reserve.cpu),
                hostUsableMemoryGB: max(0, host.memoryGB - newConfig.reserve.memoryGB),
                weights: newConfig.runtimes?.budget ?? [:],
                defaultRuntime: RuntimeID(rawValue: newConfig.runtimes?.defaultRuntime ?? "tart") ?? .tart,
                shape: { id in
                    switch id {
                    case .appleContainer:
                        return (newConfig.container?.cpus ?? 4, newConfig.container?.memoryGB ?? 8)
                    case .docker:
                        return (newConfig.docker?.cpus ?? 2, newConfig.docker?.memoryGB ?? 4)
                    case .host:
                        return (1, 1)
                    default:
                        return (newConfig.vm.cpuCount, newConfig.vm.memoryGB)
                    }
                }
            )
            caps = partition.caps
            if let dockerConfig = newConfig.docker, let partitionCap = caps[.docker] {
                caps[.docker] = min(partitionCap, dockerConfig.maxSlots)
            }
        }
        routingState.withLock { $0 = RoutingState(model: model, caps: caps) }
        // Fleet label edits must reach the forge's demand query too —
        // queuedJobs(matching:) filters by the forge's label set.
        forgeState.withLock { state in
            for (key, forge) in state.byPlatform {
                if let githubForge = forge as? GitHubForge {
                    state.byPlatform[key] = GitHubForge(
                        credentials: githubForge.credentials,
                        labels: newConfig.labels,
                        client: githubForge.client,
                        account: githubForge.account
                    )
                }
            }
        }
        let poolNames = model.pools.keys.map(\.rawValue).sorted().joined(separator: ", ")
        let capNote = caps.isEmpty ? "fleet cap" : "partitioned caps"
        Log.info("engine", "routing reloaded (pools: \(poolNames), \(capNote))")
    }
}
