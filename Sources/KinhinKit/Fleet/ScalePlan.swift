import Foundation

/// One pure scaling decision for a reconcile pass: how many instances to
/// start (and for which account and runtime) and which idle ones to delete.
///
/// The spawn target, the account and runtime choice, the per-pool caps, the
/// backoff holds and scale-down used to be four partial views of the same
/// question. They all read from here so they cannot disagree, and the whole
/// policy is testable without a fleet, a clock or any I/O.
///
/// Demand semantics differ per forge. Classic forges report *queued* jobs
/// only: a busy VM's job is no longer in the queue, so a busy VM covers none
/// of it. A scale-set forge (`Forge.queueIncludesRunning`) reports every
/// assigned job, running ones included, so there a busy VM covers its own job.
struct ScalePlan: Equatable {
    /// One instance to start.
    struct Slot: Equatable {
        var account: String
        var runtime: RuntimeID
    }

    struct Input {
        var records: [VMRecord]
        /// Jobs per account and pool (runtime) for this pass.
        var demand: [String: [RuntimeID: Int]]
        /// Accounts whose demand counts running jobs too (scale-set forges).
        var includesRunning: Set<String> = []
        /// Accounts with a working forge (candidates for a new instance).
        var attached: Set<String>
        /// Accounts whose queue could not be read this pass.
        var failedForges: Set<String> = []
        var runnersPerVM = 1
        var minRunners = 0
        var maxRunners: Int
        /// Host-resource ceiling on concurrent instances.
        var capacityCap: Int
        /// Per-runtime partition caps; a runtime with no entry is uncapped.
        var poolCaps: [RuntimeID: Int] = [:]
        /// Runtimes backing off after repeated start failures.
        var heldRuntimes: Set<RuntimeID> = []
        /// Runtimes that have a configured pool.
        var existingPools: Set<RuntimeID>
        var defaultRuntime: RuntimeID
    }

    /// Instances that should exist for the queue (published in the status).
    var desired: Int
    /// Instances to have in total after this pass's spawns.
    var target: Int
    var active: Int
    /// Unmet demand in instances, per pool.
    var unmetByPool: [RuntimeID: Int]
    /// Instances to start, in order.
    var slots: [Slot]
    /// Idle instances to delete.
    var scaleDown: [String]
    /// A surplus exists but an unreadable queue holds the scale-down.
    var scaleDownHeld: Bool

    static func make(_ input: Input) -> ScalePlan {
        let rpv = max(1, input.runnersPerVM)
        let cap = min(input.maxRunners, input.capacityCap)
        let queueDepth = input.demand.values.reduce(0) { $0 + $1.values.reduce(0, +) }
        let desired = Autoscaler.desiredCount(
            queueDepth: queueDepth, minRunners: input.minRunners, maxRunners: input.maxRunners,
            capacityCap: input.capacityCap, runnersPerVM: rpv)
        let active = input.records.filter { $0.phase.isActive }
        let unmet = unmetByPool(records: active, input: input)

        // A pool at its cap, backing off, or without a runtime cannot take
        // more instances, so its unmet demand must not inflate the target.
        var spawnable = 0
        for (pool, count) in unmet {
            spawnable += min(count, headroom(pool, records: active, input: input))
        }
        let target = min(cap, max(desired, active.count + spawnable))

        var plan = ScalePlan(
            desired: desired, target: target, active: active.count, unmetByPool: unmet, slots: [], scaleDown: [],
            scaleDownHeld: false)
        plan.slots = slots(count: target - active.count, active: active, input: input)

        if active.count > desired {
            if input.failedForges.isEmpty {
                plan.scaleDown = scaleDown(active: active, surplus: active.count - desired, input: input)
            } else {
                plan.scaleDownHeld = true
            }
        }
        return plan
    }

    // MARK: - Coverage

    /// Whether `record` covers queued demand of its account. Busy instances
    /// cover only demand that counts running jobs.
    private static func covers(_ record: VMRecord, includesRunning: Set<String>) -> Bool {
        record.phase != .busy || includesRunning.contains(record.platform ?? "")
    }

    private static func pool(of record: VMRecord, input: Input) -> RuntimeID {
        RuntimeID(rawValue: record.runtime ?? "") ?? input.defaultRuntime
    }

    /// Unmet instances per pool: for each demand kind (queued-only, or
    /// including running) the instances its jobs need minus the instances of
    /// that kind that can serve them.
    private static func unmetByPool(records: [VMRecord], input: Input) -> [RuntimeID: Int] {
        let rpv = max(1, input.runnersPerVM)
        var jobs: [RuntimeID: [Bool: Int]] = [:]  // pool → includesRunning → jobs
        for (account, pools) in input.demand {
            let kind = input.includesRunning.contains(account)
            for (pool, count) in pools where count > 0 { jobs[pool, default: [:]][kind, default: 0] += count }
        }
        var supply: [RuntimeID: [Bool: Int]] = [:]
        for record in records {
            let kind = input.includesRunning.contains(record.platform ?? "")
            guard covers(record, includesRunning: input.includesRunning) else { continue }
            supply[pool(of: record, input: input), default: [:]][kind, default: 0] += 1
        }
        var result: [RuntimeID: Int] = [:]
        for (pool, byKind) in jobs {
            var unmet = 0
            for (kind, count) in byKind {
                let wanted = Int(ceil(Double(count) / Double(rpv)))
                unmet += max(0, wanted - (supply[pool]?[kind] ?? 0))
            }
            if unmet > 0 { result[pool] = unmet }
        }
        return result
    }

    /// How many more instances `pool` may take.
    private static func headroom(_ pool: RuntimeID, records: [VMRecord], input: Input) -> Int {
        guard input.existingPools.contains(pool), !input.heldRuntimes.contains(pool) else { return 0 }
        let running = records.count { Self.pool(of: $0, input: input) == pool }
        return max(0, (input.poolCaps[pool] ?? Int.max) - running)
    }

    // MARK: - Spawn

    private static func slots(count: Int, active: [VMRecord], input: Input) -> [Slot] {
        guard count > 0 else { return [] }
        let totals = input.demand.mapValues { $0.values.reduce(0, +) }
        var sim = active
        var out: [Slot] = []
        for _ in 0..<count {
            // The account with the most unmet demand (its jobs minus the
            // instances that can serve them).
            var coverage: [String: Int] = [:]
            for record in sim where covers(record, includesRunning: input.includesRunning) {
                if let account = record.platform { coverage[account, default: 0] += 1 }
            }
            let account = ForgeDemand.assignAccount(demand: totals, active: coverage, attached: input.attached)

            // The pool with the most unmet demand within its capacity.
            let unmet = unmetByPool(records: sim, input: input)
            var caps = input.poolCaps
            for held in input.heldRuntimes { caps[held] = 0 }
            var running: [RuntimeID: Int] = [:]
            for record in sim { running[pool(of: record, input: input), default: 0] += 1 }
            let chosen = selectRuntime(
                unmet: unmet, active: running, caps: caps, fallback: input.defaultRuntime,
                poolExists: input.existingPools.contains)
            if input.heldRuntimes.contains(chosen) { break }  // every pool with demand is backing off

            out.append(Slot(account: account, runtime: chosen))
            var record = VMRecord(id: "plan-\(out.count)", phase: .cloning)
            record.platform = account
            record.runtime = chosen.rawValue
            sim.append(record)
        }
        return out
    }

    /// The runtime for a new instance: among pools with unmet demand the one
    /// with the most, never beyond its capacity partition. Ties break
    /// alphabetically by runtime id; with no unmet demand anywhere, `fallback`
    /// wins (uncapped within the global target).
    static func selectRuntime(
        unmet: [RuntimeID: Int], active: [RuntimeID: Int], caps: [RuntimeID: Int], fallback: RuntimeID,
        poolExists: (RuntimeID) -> Bool
    ) -> RuntimeID {
        var best: RuntimeID = fallback
        var bestUnmet = -1
        for (id, count) in unmet.sorted(by: { $0.key.rawValue < $1.key.rawValue }) {
            guard poolExists(id) else { continue }
            let cap = caps[id] ?? Int.max
            let running = active[id] ?? 0
            guard running < cap else { continue }  // partition exhausted
            let effective = min(count, cap - running)
            if effective > bestUnmet {
                bestUnmet = effective
                best = id
            }
        }
        return best
    }

    // MARK: - Scale down

    /// Idle (ready) instances beyond `desired`, oldest first, never one whose
    /// removal would leave its pool short of its queued jobs.
    private static func scaleDown(active: [VMRecord], surplus: Int, input: Input) -> [String] {
        var remaining = active
        var surplus = surplus
        var doomed: [String] = []
        let idle = active.filter { $0.phase == .ready }.sorted { $0.createdAt < $1.createdAt }
        for record in idle where surplus > 0 {
            let without = remaining.filter { $0.id != record.id }
            let poolID = pool(of: record, input: input)
            guard unmetByPool(records: without, input: input)[poolID] == nil else { continue }
            remaining = without
            doomed.append(record.id)
            surplus -= 1
        }
        return doomed
    }

    // MARK: - Disk

    /// The leading slots the disk can hold. Each slot costs its runtime's
    /// per-instance disk plus the reserve (host slots cost none); the first
    /// slot that does not fit ends the list and is reported.
    static func admitByDisk(
        _ slots: [Slot], freeDiskGB: Int, reserveGB: Int, diskPerInstanceGB: (RuntimeID) -> Int
    ) -> (admitted: [Slot], blocked: (runtime: RuntimeID, availableGB: Int, neededGB: Int)?) {
        var free = freeDiskGB
        var admitted: [Slot] = []
        for slot in slots {
            if slot.runtime != .host {
                let perVM = diskPerInstanceGB(slot.runtime)
                let needed = perVM + reserveGB
                if free < needed { return (admitted, (slot.runtime, free, needed)) }
                free -= perVM
            }
            admitted.append(slot)
        }
        return (admitted, nil)
    }
}

extension Forge {
    /// Whether `queuedJobs()` counts jobs already running on a runner. True
    /// for the GitHub scale-set forge (`totalAssignedJobs`); classic forges
    /// report queued-only work, so a busy VM is no longer part of it.
    /// Scale-set is the only `.jitConfig` forge.
    var queueIncludesRunning: Bool {
        if case .jitConfig = registration { return true }
        return false
    }
}
