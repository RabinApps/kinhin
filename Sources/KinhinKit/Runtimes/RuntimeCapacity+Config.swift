import Foundation

// RuntimeCapacity — the partition as a config asks for it. The engine's init,
// its live reload, the Runtimes pane and the budget sliders' preview all go
// through here, so the caps a user previews are the caps the fleet enforces.
extension RuntimeCapacity {
    /// One instance's shape on `runtime` under `config`, with the engine's
    /// defaults when a section leaves a value out. Host slots cost the Mac
    /// nothing beyond the user's own processes (1/1 keeps the math non-zero
    /// without shrinking other pools).
    static func shape(of runtime: RuntimeID, in config: KinhinConfig) -> (cpu: Int, memoryGB: Int) {
        switch runtime {
        case .appleContainer: return (config.container?.cpus ?? 4, config.container?.memoryGB ?? 8)
        case .docker: return (config.docker?.cpus ?? 2, config.docker?.memoryGB ?? 4)
        case .host: return (1, 1)
        case .tart: return (config.vm.cpuCount, config.vm.memoryGB)
        }
    }

    /// True when `config` splits the host between runtimes: a `runtimes:`
    /// section plus a Linux runtime to split with. Single-pool fleets keep
    /// the fleet cap (and the legacy status shape: no per-runtime caps).
    static func isPartitioned(_ config: KinhinConfig) -> Bool {
        config.runtimes != nil && (config.container != nil || config.docker != nil)
    }

    /// Per-runtime instance caps for `config` on `host`; empty for a
    /// single-pool fleet.
    static func caps(for config: KinhinConfig, host: HostResources) -> [RuntimeID: Int] {
        guard isPartitioned(config), let routing = config.runtimes else { return [:] }
        return partitionedCaps(
            for: config, host: host, weights: routing.budget,
            defaultRuntime: RuntimeID(rawValue: routing.defaultRuntime) ?? .tart)
    }

    /// Caps at an explicit split (the sliders' candidate budget), always
    /// partitioned: deterministic, no overcommit, and Docker's hard slot
    /// cap applied on top of its share.
    static func partitionedCaps(
        for config: KinhinConfig, host: HostResources, weights: [String: Double], defaultRuntime: RuntimeID
    ) -> [RuntimeID: Int] {
        var caps = partition(
            hostUsableCPU: max(0, host.logicalCores - config.reserve.cpu),
            hostUsableMemoryGB: max(0, host.memoryGB - config.reserve.memoryGB),
            weights: weights,
            defaultRuntime: defaultRuntime,
            shape: { shape(of: $0, in: config) }
        ).caps
        if let docker = config.docker, let share = caps[.docker] {
            caps[.docker] = min(share, docker.maxSlots)
        }
        return caps
    }
}
