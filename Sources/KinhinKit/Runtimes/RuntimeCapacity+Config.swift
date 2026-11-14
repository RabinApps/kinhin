import Foundation

// RuntimeCapacity — the partition as a config asks for it. The engine's init,
// its live reload, the Runtimes pane and the budget sliders' preview all go
// through here, so the caps a user previews are the caps the fleet enforces.
extension RuntimeCapacity {
    /// One instance's shape on `runtime` under `config`, with the engine's
    /// defaults when a section leaves a value out. Host slots cost the Mac
    /// nothing beyond the user's own processes (1/1 keeps the math non-zero
    /// without shrinking other pools). With named container pools, the
    /// Apple container shape is the smallest CPU and the smallest memory of
    /// any pool, so the count it yields is an upper bound and the scale plan
    /// admits each instance by its own pool's shape (`containerBudget`).
    static func shape(of runtime: RuntimeID, in config: KinhinConfig) -> (cpu: Int, memoryGB: Int) {
        switch runtime {
        case .appleContainer:
            if let pools = config.container?.pools.filter(\.enabled), !pools.isEmpty {
                return (pools.map(\.cpus).min() ?? 4, pools.map(\.memoryGB).min() ?? 8)
            }
            return (config.container?.cpus ?? 4, config.container?.memoryGB ?? 8)
        case .docker: return (config.docker?.cpus ?? 2, config.docker?.memoryGB ?? 4)
        case .host: return (1, 1)
        case .tart: return (config.vm.cpuCount, config.vm.memoryGB)
        }
    }

    /// True when `config` splits the host between runtimes: a `runtimes:`
    /// section plus a Linux runtime to split with. Single-pool fleets keep
    /// the fleet cap (and the legacy status shape: no per-runtime caps).
    static func isPartitioned(_ config: KinhinConfig) -> Bool {
        config.runtimes != nil && (config.activeContainer != nil || config.activeDocker != nil)
    }

    /// The CPU and memory the Apple container runtime may use in all, which
    /// its named pools share: its partition share in a mixed fleet, else the
    /// host minus the reserve. Nil without named pools, whose one shape the
    /// count caps already size exactly.
    static func containerBudget(for config: KinhinConfig, host: HostResources) -> Budget? {
        guard let pools = config.activeContainer?.pools, !pools.isEmpty else { return nil }
        let usable = Budget(
            cpu: max(0, host.logicalCores - config.reserve.cpu),
            memoryGB: max(0, host.memoryGB - config.reserve.memoryGB))
        guard isPartitioned(config), let routing = config.runtimes else { return usable }
        return shares(
            hostUsableCPU: usable.cpu, hostUsableMemoryGB: usable.memoryGB, weights: routing.budget,
            defaultRuntime: routing.defaultRuntime)[.appleContainer] ?? Budget(cpu: 0, memoryGB: 0)
    }

    /// Per-runtime instance caps for `config` on `host`; empty for a
    /// single-pool fleet.
    static func caps(for config: KinhinConfig, host: HostResources) -> [RuntimeID: Int] {
        guard isPartitioned(config), let routing = config.runtimes else { return [:] }
        return partitionedCaps(
            for: config, host: host, weights: routing.budget,
            defaultRuntime: routing.defaultRuntime)
    }

    /// Caps at an explicit split (the sliders' candidate budget), always
    /// partitioned: deterministic, no overcommit, and Docker's hard slot
    /// cap applied on top of its share.
    static func partitionedCaps(
        for config: KinhinConfig, host: HostResources, weights: [String: Double], defaultRuntime: RuntimeID
    ) -> [RuntimeID: Int] {
        // A disabled pool's weight is dropped, so its share falls to the default runtime like any unclaimed remainder.
        var weights = weights
        if !config.tartEnabled { weights[RuntimeID.tart.rawValue] = nil }
        if config.activeContainer == nil { weights[RuntimeID.appleContainer.rawValue] = nil }
        if config.activeDocker == nil { weights[RuntimeID.docker.rawValue] = nil }
        var caps = partition(
            hostUsableCPU: max(0, host.logicalCores - config.reserve.cpu),
            hostUsableMemoryGB: max(0, host.memoryGB - config.reserve.memoryGB),
            weights: weights,
            defaultRuntime: defaultRuntime,
            shape: { shape(of: $0, in: config) }
        ).caps
        if let docker = config.activeDocker, let share = caps[.docker] {
            caps[.docker] = min(share, docker.maxSlots)
        }
        return caps
    }
}
