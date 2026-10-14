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
        /// The Tart image a new instance clones: nil = the base image (or not Tart).
        var image: String? = nil
        /// A warm instance of `image` to bind instead of cloning.
        var claim: String? = nil
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
        /// Booted, unregistered instances to keep per Tart image, keyed by image name ("" = the base
        /// image). Absent or 0 = off.
        var warmPool: [String: Int] = [:]
        /// A warm instance older than this is recycled.
        var warmMaxAge: TimeInterval = 3600
        /// Queued Tart jobs per named or derived image; the base image takes the rest of the Tart demand.
        var imageDemand: [String: Int] = [:]
        var now = Date()
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
    /// Warm instances bound to Tart slots instead of cloning (each slot's `claim`), oldest first.
    var claims: [String] = []
    /// Warm instances to delete: stale, or in the way of a slot the cap needs.
    var evict: [String] = []
    /// Warm instances to start so each pool is full, per image ("" = the base image).
    var warmSpawn: [String: Int] = [:]
    /// A surplus exists but an unreadable queue holds the scale-down.
    var scaleDownHeld: Bool

    static func make(_ input: Input) -> ScalePlan {
        let rpv = max(1, input.runnersPerVM)
        let cap = min(input.maxRunners, input.capacityCap)
        let queueDepth = input.demand.values.reduce(0) { $0 + $1.values.reduce(0, +) }
        let desired = Autoscaler.desiredCount(
            queueDepth: queueDepth, minRunners: input.minRunners, maxRunners: input.maxRunners,
            capacityCap: input.capacityCap, runnersPerVM: rpv)
        // Warm instances serve no demand by themselves (they have no account and are not
        // registered) and are evictable, so every demand figure below counts only live ones.
        let all = input.records.filter { $0.phase.isActive }
        let active = all.filter { $0.phase != .warm }
        let warm = all.filter { $0.phase == .warm }.sorted { $0.createdAt < $1.createdAt }
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
        applyWarm(warm, to: &plan, live: active.count, cap: cap, input: input)

        if active.count > desired {
            if input.failedForges.isEmpty {
                plan.scaleDown = scaleDown(active: active, surplus: active.count - desired, input: input)
            } else {
                plan.scaleDownHeld = true
            }
        }
        return plan
    }

    // MARK: - Warm pool

    /// Claims warm instances for the Tart slots, evicts the stale and the overflow, and tops the
    /// pool up when nothing else needs the slots.
    private static func applyWarm(_ warm: [VMRecord], to plan: inout ScalePlan, live: Int, cap: Int, input: Input) {
        // A warm VM whose pool is off or was removed (its images: entry dropped or renamed) serves
        // nothing and holds a slot, so it is recycled now rather than at `warmMaxAge`.
        let stale = Set(
            warm.filter {
                input.now.timeIntervalSince($0.createdAt) > input.warmMaxAge
                    || (input.warmPool[$0.image ?? ""] ?? 0) == 0
            }.map(\.id))
        let fresh = warm.filter { !stale.contains($0.id) }
        // A Tart slot binds the oldest fresh warm instance of its own image, if there is one.
        for index in plan.slots.indices where plan.slots[index].runtime == .tart {
            let image = plan.slots[index].image ?? ""
            guard let match = fresh.first(where: { ($0.image ?? "") == image && !plan.claims.contains($0.id) })
            else { continue }
            plan.slots[index].claim = match.id
            plan.claims.append(match.id)
        }
        var evict = warm.filter { stale.contains($0.id) }.map(\.id)

        // Warm instances left after the claims still occupy slots: drop the surplus the cap cannot hold.
        let unclaimed = fresh.filter { !plan.claims.contains($0.id) }
        let overflow = live + plan.slots.count + unclaimed.count - cap
        var dropped = Set<String>()
        if overflow > 0 {
            dropped = Set(unclaimed.prefix(overflow).map(\.id))
            evict += dropped
        }
        plan.evict = evict

        let tart = RuntimeID.tart
        guard input.warmPool.values.contains(where: { $0 > 0 }), plan.slots.isEmpty, input.failedForges.isEmpty,
            input.existingPools.contains(tart), !input.heldRuntimes.contains(tart)
        else { return }
        // Warm instances that survive, per image: each pool tops up from its own count.
        var kept: [String: Int] = [:]
        for record in unclaimed where !dropped.contains(record.id) { kept[record.image ?? "", default: 0] += 1 }
        let tartRunning = input.records.count { $0.phase.isActive && ($0.runtimeID ?? input.defaultRuntime) == tart }
        var room = min(
            cap - max(plan.target, live) - kept.values.reduce(0, +),
            (input.poolCaps[tart] ?? Int.max) - tartRunning)
        // The base image first (its key sorts first), then named images in name order.
        for image in input.warmPool.keys.sorted() {
            let want = input.warmPool[image] ?? 0
            let spawn = max(0, min(want - (kept[image] ?? 0), room))
            if spawn > 0 {
                plan.warmSpawn[image] = spawn
                room -= spawn
            }
        }
    }

    /// The image a new Tart instance clones: the named or derived image with the most unmet queued
    /// jobs, else the base image (nil). Ties go to a derived image. `active` counts the instances
    /// that serve demand per image ("" = the base image).
    static func chooseImage(queuedTart: Int, byImage: [String: Int], active: [String: Int]) -> String? {
        guard !byImage.isEmpty else { return nil }
        let derivedTotal = byImage.values.reduce(0, +)
        var best: (image: String?, unmet: Int) = (nil, (queuedTart - derivedTotal) - (active[""] ?? 0))
        for (image, count) in byImage.sorted(by: { $0.key < $1.key }) {
            let unmet = count - (active[image] ?? 0)
            if unmet > 0, unmet >= best.unmet { best = (image, unmet) }
        }
        return best.unmet > 0 ? best.image : nil
    }

    // MARK: - Coverage

    /// Whether `record` covers queued demand of its account. Busy instances
    /// cover only demand that counts running jobs.
    private static func covers(_ record: VMRecord, includesRunning: Set<String>) -> Bool {
        record.phase != .busy || includesRunning.contains(record.platform ?? "")
    }

    private static func pool(of record: VMRecord, input: Input) -> RuntimeID {
        record.runtimeID ?? input.defaultRuntime
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
        let queuedTart = input.demand.values.reduce(0) { $0 + ($1[.tart] ?? 0) }
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

            // The image for a Tart slot, counting only instances that serve demand (warm ones do not).
            var image: String?
            if chosen == .tart {
                var served: [String: Int] = [:]
                for record in sim where pool(of: record, input: input) == .tart {
                    served[record.image ?? "", default: 0] += 1
                }
                image = chooseImage(queuedTart: queuedTart, byImage: input.imageDemand, active: served)
            }

            out.append(Slot(account: account, runtime: chosen, image: image))
            var record = VMRecord(id: "plan-\(out.count)", phase: .cloning)
            record.platform = account
            record.runtimeID = chosen
            record.image = image
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

    /// The leading slots the disk can hold. Each slot costs its per-instance disk plus the reserve
    /// (host slots cost none); the first slot that does not fit ends the list and is reported.
    /// The disk is per slot, not per runtime, because a named Tart image can be larger than the base.
    static func admitByDisk(
        _ slots: [Slot], freeDiskGB: Int, reserveGB: Int, diskPerInstanceGB: (Slot) -> Int
    ) -> (admitted: [Slot], blocked: (runtime: RuntimeID, availableGB: Int, neededGB: Int)?) {
        var free = freeDiskGB
        var admitted: [Slot] = []
        for slot in slots {
            if slot.runtime != .host {
                let perVM = diskPerInstanceGB(slot)
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
