import Foundation

// ScalePlan — named container pools (`container.pools:`): per-pool demand, per-pool `min_idle` floors and admission
// by CPU and memory within the budget the pools share, the way named Tart images get their own demand and floors.
//
// Each pool is a key within the Apple container runtime, as each image is within Tart (`IdleKey.pool`, `Slot.pool`,
// `VMRecord.pool`). An idle runner of one pool never counts as supply for another pool's jobs (their labels differ,
// so the forge cannot hand them over). A new Apple container slot goes to the pool with the most unmet jobs whose
// shape still fits: under the pool's `max:` and within what the live Apple container instances leave of the budget.
// The runtime's count cap (`poolCaps`, sized from the smallest pool shape) still bounds the instance count.
//
// Without named pools (`containerPools` empty) none of this applies, and the plan is exactly what it was before pools.
extension ScalePlan {
    /// One named container pool as the plan sizes it.
    struct ContainerPoolShape: Equatable {
        var cpus: Int
        var memoryGB: Int
        /// The pool's own instance cap (`max:`); nil = none.
        var max: Int?
    }

    // MARK: - Membership

    /// The named pool an Apple container record counts toward: its own when still configured, else the default
    /// pool. "" without named pools.
    static func containerPool(of record: VMRecord, input: Input) -> String {
        guard !input.containerPools.isEmpty else { return "" }
        if let name = record.pool, input.containerPools[name] != nil { return name }
        return input.defaultContainerPool
    }

    /// The CPU and memory the Apple container instances among `records` take, each at its pool's shape.
    static func containerUsage(records: [VMRecord], input: Input) -> RuntimeCapacity.Budget {
        var used = RuntimeCapacity.Budget(cpu: 0, memoryGB: 0)
        for record in records where pool(of: record, input: input) == .appleContainer {
            guard let shape = input.containerPools[containerPool(of: record, input: input)] else { continue }
            used.cpu += shape.cpus
            used.memoryGB += shape.memoryGB
        }
        return used
    }

    // MARK: - Admission

    /// Whether one more instance of the named pool `name` fits beside `records`: under the pool's `max:`, and with
    /// its CPU and memory within what the Apple container instances leave of the shared budget.
    static func containerPoolFits(_ name: String, records: [VMRecord], input: Input) -> Bool {
        guard let shape = input.containerPools[name], !input.unavailableContainerPools.contains(name) else {
            return false
        }
        if let max = shape.max {
            let running = records.count {
                pool(of: $0, input: input) == .appleContainer && containerPool(of: $0, input: input) == name
            }
            if running >= max { return false }
        }
        guard let budget = input.containerBudget else { return true }
        let used = containerUsage(records: records, input: input)
        return used.cpu + shape.cpus <= budget.cpu && used.memoryGB + shape.memoryGB <= budget.memoryGB
    }

    // MARK: - Demand

    /// Instances each named pool's queued jobs still need beyond its free ones, summed over the pools; nil without
    /// named pools. `unmetByPool` takes the larger of this and its runtime-wide figure.
    static func containerUnmetByPool(records: [VMRecord], input: Input) -> Int? {
        guard !input.containerPools.isEmpty else { return nil }
        return input.containerPools.keys.reduce(0) { total, name in
            total + max(0, containerPoolUnmet(name, records: records, input: input))
        }
    }

    /// The named pool `name`'s queued need minus its free instances (negative when it has spare ones).
    static func containerPoolUnmet(_ name: String, records: [VMRecord], input: Input) -> Int {
        let key = IdleKey(runtime: .appleContainer, pool: name)
        return queuedNeed(key, input: input) - freeInstances(key, records: records, input: input)
    }

    /// The named pool a new Apple container instance starts in: the one with the most unmet jobs that fits (ties: the
    /// first by name). When pools have waiting jobs but none of them fits, nil: a runner of another pool could not
    /// take those jobs. With no jobs waiting anywhere (a `min_runners` top-up), the default pool if it fits, else the
    /// first pool that does; nil when none fits.
    static func chooseContainerPool(records: [VMRecord], input: Input) -> String? {
        let names = input.containerPools.keys.sorted()
        let fitting = names.filter { containerPoolFits($0, records: records, input: input) }
        var best: (name: String, unmet: Int)?
        var waiting = false
        for name in names {
            let unmet = containerPoolUnmet(name, records: records, input: input)
            guard unmet > 0 else { continue }
            waiting = true
            if fitting.contains(name), unmet > (best?.unmet ?? 0) { best = (name, unmet) }
        }
        if let best { return best.name }
        if waiting { return nil }
        return fitting.contains(input.defaultContainerPool) ? input.defaultContainerPool : fitting.first
    }
}

// MARK: - Pools left out of a pass

extension ScalePlan.Input {
    /// Leaves the named container pools `names` out of this pass, before anything is sized: their queued jobs
    /// (`demandByAccount`: per account and pool) leave the demand, their `min_idle` floors go, and they may start
    /// nothing, not even a `min_runners` top-up. Their jobs then wait unserved rather than start another pool's runner
    /// (its labels could not take them), and they take no room, evict nothing and cause no failed start. Their running
    /// instances still count, for their CPU and memory.
    mutating func exclude(containerPools names: Set<String>, demandByAccount: [String: [String: Int]]) {
        guard !names.isEmpty else { return }
        unavailableContainerPools.formUnion(names)
        for name in names { containerPoolDemand[name] = nil }
        for (account, pools) in demandByAccount {
            let dropped = names.reduce(0) { $0 + (pools[$1] ?? 0) }
            guard dropped > 0, let jobs = demand[account]?[.appleContainer] else { continue }
            demand[account]?[.appleContainer] = jobs > dropped ? jobs - dropped : nil
        }
        minIdle = minIdle.filter { !($0.key.runtime == .appleContainer && names.contains($0.key.pool)) }
    }
}
