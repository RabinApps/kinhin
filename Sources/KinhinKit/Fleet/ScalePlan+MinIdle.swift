import Foundation

// ScalePlan — `min_idle`: a floor of registered, idle runners per pool and per Tart image, kept beside the
// queue-driven slots so the forge always lists a free runner for each label set the fleet serves.
//
// The floor counts an instance that is starting (cloning, booting, registering) or registered and waiting (`.ready`)
// for its pool or image. A busy instance does not count — so a replacement starts as soon as a runner picks up a
// job — except where the forge's demand includes running jobs (scale sets), where it covers its own job. Warm
// instances are not registered and pooled in-flight clones belong to the warm pool, so neither counts. Top-ups come
// after the queue's slots, never past a pool's cap, the global cap or a held runtime, and warm instances are evicted
// for them like for any other slot. `min_runners` is unchanged: it stays one fleet-wide count, busy runners included.
extension ScalePlan {
    // MARK: - Keys

    /// A pool, or one Tart image within the Tart pool, that keeps its own floor. Tart instances key by image
    /// ("" = the base `image:`); every other runtime is a single key with image "".
    struct IdleKey: Hashable, Comparable, CustomStringConvertible {
        var runtime: RuntimeID
        var image: String = ""

        static func < (lhs: IdleKey, rhs: IdleKey) -> Bool {
            (lhs.runtime.rawValue, lhs.image) < (rhs.runtime.rawValue, rhs.image)
        }

        var description: String { image.isEmpty ? runtime.rawValue : "\(runtime.rawValue)/\(image)" }
    }

    static func idleKey(of record: VMRecord, input: Input) -> IdleKey {
        let runtime = pool(of: record, input: input)
        return IdleKey(runtime: runtime, image: runtime == .tart ? record.image ?? "" : "")
    }

    /// True when some Tart image keeps a floor. Idle runners of one image must then not count as supply for another
    /// image's queued jobs (their labels differ, so the forge cannot hand them over), so the Tart pool's unmet demand
    /// and the image a new slot clones are worked out per image. Off, the plan is exactly what it was before
    /// `min_idle`.
    static func imageAware(_ input: Input) -> Bool {
        input.minIdle.contains { $0.key.runtime == .tart && $0.value > 0 }
    }

    // MARK: - Demand per key

    /// Instances `key`'s queued jobs need. A Tart image's jobs are its share of `imageDemand`; the base image takes
    /// the Tart jobs no named image claimed (never fewer than its synthesized entry counted, as `chooseImage` does).
    static func queuedNeed(_ key: IdleKey, input: Input) -> Int {
        let jobs: Int
        if key.runtime == .tart {
            if key.image.isEmpty {
                let queuedTart = input.demand.values.reduce(0) { $0 + ($1[.tart] ?? 0) }
                let named = input.imageDemand.filter { !$0.key.isEmpty }.values.reduce(0, +)
                jobs = max(queuedTart - named, input.imageDemand[""] ?? 0)
            } else {
                jobs = input.imageDemand[key.image] ?? 0
            }
        } else {
            jobs = input.demand.values.reduce(0) { $0 + ($1[key.runtime] ?? 0) }
        }
        return Int(ceil(Double(jobs) / Double(max(1, input.runnersPerVM))))
    }

    /// Instances of `key` among `records` that are, or will be, free for its jobs: starting or registered and idle
    /// (busy ones only where the demand counts running jobs). Warm instances never count.
    static func freeInstances(_ key: IdleKey, records: [VMRecord], input: Input) -> Int {
        records.count {
            $0.phase != .warm && covers($0, includesRunning: input.includesRunning)
                && idleKey(of: $0, input: input) == key
        }
    }

    /// How many instances `key` is short of its queued need plus its floor. 0 when the key keeps no floor.
    static func idleShortfall(_ key: IdleKey, records: [VMRecord], input: Input) -> Int {
        let floor = input.minIdle[key] ?? 0
        guard floor > 0 else { return 0 }
        return max(0, queuedNeed(key, input: input) + floor - freeInstances(key, records: records, input: input))
    }

    /// The Tart pool's unmet demand summed per image, or nil when no Tart image keeps a floor (see `imageAware`).
    /// `unmetByPool` takes the larger of this and its pool-wide figure.
    static func tartUnmetByImage(records: [VMRecord], input: Input) -> Int? {
        guard imageAware(input) else { return nil }
        let images = Set(input.imageDemand.keys.filter { !$0.isEmpty }).union([""])
        return images.reduce(0) { total, image in
            let key = IdleKey(runtime: .tart, image: image)
            return total + max(0, queuedNeed(key, input: input) - freeInstances(key, records: records, input: input))
        }
    }

    /// Whether `record` counts toward its image's demand when a slot picks the image to clone. With a Tart floor, a
    /// busy instance whose job left the queue serves none of it, so it must not steer the next slot to another image.
    static func servesImageDemand(_ record: VMRecord, input: Input) -> Bool {
        !imageAware(input) || covers(record, includesRunning: input.includesRunning)
    }

    /// Whether scaling `pool` down from `remaining` to `without` leaves its queued jobs no worse served. Without a
    /// Tart floor that means none of them unmet, as before. With one, the Tart pool's demand is per image: an idle
    /// runner of one image does not serve another image's waiting job, so removing it may go ahead while that job
    /// waits, and frees its slot for the job.
    static func removalKeepsDemand(
        of pool: RuntimeID, remaining: [VMRecord], without: [VMRecord], input: Input
    ) -> Bool {
        let after = unmetByPool(records: without, input: input)[pool]
        guard imageAware(input) else { return after == nil }
        return (after ?? 0) <= (unmetByPool(records: remaining, input: input)[pool] ?? 0)
    }

    // MARK: - Top-ups

    /// Slots that bring every key back to its floor, after the queue's slots (`planned`) and within `room` more
    /// instances fleet-wide. Keys take turns, one slot per key per round in key order, so scarce room is spread
    /// rather than spent on the first key. A key whose pool is missing, held or at its cap gets none; with no forge
    /// attached nothing could register, so nothing starts.
    static func idleTopUps(
        active: [VMRecord], planned: [Slot], room: Int, reserved: [RuntimeID: Int], input: Input
    ) -> [Slot] {
        let keys = input.minIdle.filter { $0.value > 0 }.keys.sorted()
        guard !keys.isEmpty, room > 0, !input.attached.isEmpty else { return [] }
        var sim = active
        for (index, slot) in planned.enumerated() { sim.append(simulated(slot, id: "plan-\(index + 1)")) }
        let totals = input.demand.mapValues { $0.values.reduce(0, +) }
        var out: [Slot] = []
        var room = room
        var placed = true
        while room > 0, placed {
            placed = false
            for key in keys where room > 0 {
                let reservedHere = reserved[key.runtime] ?? 0
                guard idleShortfall(key, records: sim, input: input) > 0,
                    headroom(key.runtime, records: sim, input: input, reserved: reservedHere) > 0
                else { continue }
                var coverage: [String: Int] = [:]
                for record in sim where covers(record, includesRunning: input.includesRunning) {
                    if let account = record.platform { coverage[account, default: 0] += 1 }
                }
                let account = ForgeDemand.assignAccount(demand: totals, active: coverage, attached: input.attached)
                let slot = Slot(
                    account: account, runtime: key.runtime, image: key.image.isEmpty ? nil : key.image, idle: true)
                out.append(slot)
                sim.append(simulated(slot, id: "idle-\(out.count)"))
                room -= 1
                placed = true
            }
        }
        return out
    }

    /// The record a planned slot becomes, for counting what the plan already covers.
    static func simulated(_ slot: Slot, id: String) -> VMRecord {
        var record = VMRecord(id: id, phase: .cloning)
        record.platform = slot.account
        record.runtimeID = slot.runtime
        record.image = slot.image
        return record
    }
}
