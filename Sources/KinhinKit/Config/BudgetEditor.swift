import Foundation

/// Pure math for the Runtimes pane's budget editing: slider drags map to
/// validated `budget` dictionaries, shares always total 1 across the
/// configured pools, and round-trips through config text are tested.
/// No UI, no disk access.
public enum BudgetEditor {
    /// Clamps to two decimal places — slider-derived weights must not carry
    /// float noise into the YAML.
    static func clamp(_ weight: Double) -> Double {
        min(max((weight * 100).rounded() / 100, 0), 1)
    }

    /// Format for YAML output (0.4 → "0.4", 0.65 → "0.65", 1 → "1").
    static func weightText(_ weight: Double) -> String {
        String(format: "%g", weight)
    }

    /// A single slider drag: set `runtime`'s share of the whole budget and
    /// rescale every other pool — the default included — so the shares
    /// always total 1 and every established proportion survives. The
    /// default's stored weight is derived last (the engine ignores it and
    /// computes `1 − sum(others)` anyway), so it absorbs rounding drift.
    ///
    /// A zero share is written by *omitting* the key: `ConfigLoader`
    /// rejects an explicit `0`, and absence reads as 0 to the engine. No
    /// drag can therefore produce a dictionary `validate` refuses — the
    /// pane never has to snap a slider back behind the user's back.
    ///
    /// `locked` pools keep their exact share: the dragged pool is capped at
    /// `1 − sum(locked)` and only the unlocked pools absorb the change. A
    /// locked pool itself can't be dragged (the split comes back unchanged).
    public static func setShare(
        of runtime: RuntimeID,
        to fraction: Double,
        current: [String: Double],
        defaultRuntime: RuntimeID,
        locked: Set<RuntimeID> = []
    ) -> [String: Double] {
        if !locked.isEmpty {
            return setShareLocked(
                of: runtime, to: fraction, current: current, defaultRuntime: defaultRuntime, locked: locked)
        }
        let target = clamp(fraction)
        let shares = displayShares(current: current, defaultRuntime: defaultRuntime)
        let old = shares[runtime.rawValue] ?? 0
        guard abs(target - old) > 0.000_000_1 else {
            // Nothing moved: hand back a normalized copy so explicitly
            // seeded zeros (and a stored default that lies) never reach
            // the disk.
            return sanitized(shares)
        }

        // The rest rescales to fill what the dragged row no longer takes,
        // keeping the ratios the user already had.
        var others: [String: Double] = [:]
        let nonDefaultOthers = shares.keys.filter { $0 != runtime.rawValue && $0 != defaultRuntime.rawValue }
        let rest = 1 - old
        if rest > 0.000_000_1 {
            let scale = (1 - target) / rest
            for key in nonDefaultOthers where (shares[key] ?? 0) > 0 {
                let scaled = clamp((shares[key] ?? 0) * scale)
                if scaled > 0 { others[key] = scaled }
            }
        } else if !nonDefaultOthers.isEmpty {
            // The dragged row owns everything, so the pools beside it have
            // no established proportion to scale from: split the vacated
            // share evenly among them (the default, as always, takes
            // whatever rounding leaves over).
            let even = clamp((1 - target) / Double(nonDefaultOthers.count))
            for key in nonDefaultOthers where even > 0 { others[key] = even }
        }
        if runtime != defaultRuntime, target > 0 {
            others[runtime.rawValue] = target
        }
        // 2dp rounding can push the total past 1; shave the excess so the
        // dictionary stays inside the engine's sum limit.
        normalize(&others)

        var result = others
        let remainder = clamp(1 - others.values.reduce(0, +))
        if remainder > 0 { result[defaultRuntime.rawValue] = remainder }
        return result
    }

    /// The lock-aware drag: locked pools are untouched, the dragged pool is
    /// clamped to what the unlocked pools can give up (or take), and the
    /// unlocked pools scale proportionally — evenly when they were all at 0.
    private static func setShareLocked(
        of runtime: RuntimeID,
        to fraction: Double,
        current: [String: Double],
        defaultRuntime: RuntimeID,
        locked: Set<RuntimeID>
    ) -> [String: Double] {
        let shares = displayShares(current: current, defaultRuntime: defaultRuntime)
        let lockedKeys = Set(locked.map(\.rawValue))
        let draggedKey = runtime.rawValue
        let defaultKey = defaultRuntime.rawValue
        guard !lockedKeys.contains(draggedKey) else { return sanitized(shares) }

        let freeKeys = shares.keys.filter { $0 != draggedKey && !lockedKeys.contains($0) }.sorted()
        let old = shares[draggedKey] ?? 0
        let freeTotal = freeKeys.reduce(0.0) { $0 + (shares[$1] ?? 0) }
        guard !freeKeys.isEmpty else { return sanitized(shares) }

        let ceiling = floor((old + freeTotal) * 100 + 0.000_001) / 100
        let target = min(clamp(fraction), ceiling)
        let freeNew = max(0, old + freeTotal - target)

        var result: [String: Double] = [:]
        for key in shares.keys {
            if lockedKeys.contains(key) {
                result[key] = shares[key] ?? 0
            } else if key == draggedKey {
                result[key] = target
            } else if freeTotal > 0.000_000_1 {
                result[key] = clamp((shares[key] ?? 0) * freeNew / freeTotal)
            } else {
                result[key] = clamp(freeNew / Double(freeKeys.count))
            }
        }

        // The default's stored weight is derived (the engine computes the
        // remainder), so when it is free it soaks up rounding drift. When it
        // is locked or being dragged, the drift is corrected on the largest
        // unlocked non-default pool so its share stays exact.
        let nonDefaultSum = result.filter { $0.key != defaultKey }.values.reduce(0, +)
        let wantedDefault = result[defaultKey] ?? 0
        if lockedKeys.contains(defaultKey) || draggedKey == defaultKey {
            let drift = (1 - wantedDefault) - nonDefaultSum
            if abs(drift) > 0.000_000_1,
                let fix = freeKeys.filter({ $0 != defaultKey }).max(by: { (result[$0] ?? 0) < (result[$1] ?? 0) })
            {
                result[fix] = clamp((result[fix] ?? 0) + drift)
            }
        }
        var nonDefault = result.filter { $0.key != defaultKey && $0.value > 0 }
        normalize(&nonDefault)
        var final = nonDefault
        let remainder = clamp(1 - nonDefault.values.reduce(0, +))
        if remainder > 0 { final[defaultKey] = remainder }
        return final
    }

    /// The most `runtime` can take at this lock set: everything the
    /// unlocked pools hold plus its own share. A locked pool, or one with
    /// no unlocked neighbour, can't move from where it is.
    public static func maxShare(
        for runtime: RuntimeID,
        locked: Set<RuntimeID>,
        current: [String: Double],
        defaultRuntime: RuntimeID
    ) -> Double {
        let shares = displayShares(current: current, defaultRuntime: defaultRuntime)
        let old = shares[runtime.rawValue] ?? 0
        let lockedKeys = Set(locked.map(\.rawValue))
        guard !lockedKeys.contains(runtime.rawValue) else { return old }
        let free = shares.filter { $0.key != runtime.rawValue && !lockedKeys.contains($0.key) }
        guard !free.isEmpty else { return old }
        return min(1, floor((old + free.values.reduce(0, +)) * 100 + 0.000_001) / 100)
    }

    /// Whether dragging or typing into `runtime`'s share can change anything:
    /// it must be unlocked and have at least one unlocked neighbour.
    public static func canMove(runtime: RuntimeID, locked: Set<RuntimeID>, pools: [RuntimeID]) -> Bool {
        !locked.contains(runtime) && pools.contains { $0 != runtime && !locked.contains($0) }
    }

    /// A runtime joins the budget: the non-default budget is split evenly
    /// between the existing entries and the newcomer (or a token 0.25 when
    /// nothing else is budgeted). The default runtime keeps the remainder.
    static func addRuntime(
        _ runtime: RuntimeID,
        current: [String: Double],
        defaultRuntime: RuntimeID
    ) -> [String: Double] {
        var result = current
        guard result[runtime.rawValue] == nil else { return result }
        let existing = current.filter { $0.key != defaultRuntime.rawValue }
        let oldTotal = existing.values.reduce(0, +)
        let share = oldTotal > 0 ? oldTotal / Double(existing.count + 1) : 0.25
        // Shrink existing non-default entries to make room.
        let newTotal = max(0, oldTotal - share)
        if oldTotal > 0 {
            for (key, value) in existing {
                result[key] = clamp(value / oldTotal * newTotal)
            }
        }
        result[runtime.rawValue] = share
        // The default keeps the remainder, same rule as setShare — and a
        // zero remainder is written by omission, never as an explicit 0.
        let nonDefault = result.filter { $0.key != defaultRuntime.rawValue }
        let remainder = clamp(1 - nonDefault.values.reduce(0, +))
        if remainder > 0 {
            result[defaultRuntime.rawValue] = remainder
        } else {
            result.removeValue(forKey: defaultRuntime.rawValue)
        }
        return result.filter { $0.value > 0 }
    }

    /// Effective per-runtime shares in percent for display — the config
    /// weights plus the default's implicit remainder, so sliders and text
    /// always agree with what the engine partitions.
    public static func displayShares(current: [String: Double], defaultRuntime: RuntimeID) -> [String: Double] {
        var result = current
        let nonDefaultTotal = current.filter { $0.key != defaultRuntime.rawValue }.values.reduce(0, +)
        result[defaultRuntime.rawValue] = clamp(1 - nonDefaultTotal)
        return result
    }

    /// Drops zero and negative weights: `validate` rejects them and the
    /// engine reads an absent key as 0, so omission is the only spelling
    /// of "this pool gets nothing".
    public static func sanitized(_ budget: [String: Double]) -> [String: Double] {
        budget.filter { $0.value > 0 }
    }

    /// Rounding each weight to 2dp can push the total a cent above 1;
    /// shave the excess off the largest weights until it fits.
    private static func normalize(_ weights: inout [String: Double]) {
        for _ in 0..<8 where weights.values.reduce(0, +) > 1.000_000_1 {
            guard let largest = weights.max(by: { $0.value < $1.value })?.key else { return }
            let shaved = clamp((weights[largest] ?? 0) - 0.01)
            if shaved > 0 {
                weights[largest] = shaved
            } else {
                weights.removeValue(forKey: largest)
            }
        }
    }

    /// Instance caps at a candidate split, for live UI previews ("cap N"
    /// next to each slider) — the engine's own partition for `config` at
    /// these weights (shapes, defaults and Docker's slot cap included).
    /// Pure: no disk, no probing.
    public static func previewCaps(
        config: KinhinConfig, host: HostResources, weights: [String: Double], defaultRuntime: RuntimeID
    ) -> [RuntimeID: Int] {
        RuntimeCapacity.partitionedCaps(for: config, host: host, weights: weights, defaultRuntime: defaultRuntime)
    }

    /// Routes whose target runtime cannot run a single instance at this
    /// split (cap 0) — or whose runtime isn't configured at all. Each entry
    /// is a human-readable warning; empty means the split can serve every
    /// route. Host routes are never starved: host runners draw no VM/container
    /// budget ("cap n/a" in the pane), so no split can strand them.
    public static func starvedRoutes(
        routes: [KinhinConfig.RuntimeConfig.Route],
        caps: [RuntimeID: Int],
        configuredRuntimes: Set<RuntimeID>,
        isPartitioned: Bool = true
    ) -> [String] {
        // No budget configured: the fleet isn't partitioned (pools read
        // "cap n/a"), so no split has stranded anything yet.
        guard isPartitioned else { return [] }
        var warnings: [String] = []
        var seen: Set<String> = []
        for route in routes {
            let runtime = route.runtime
            // Host runners draw no partitioned budget, so they have no cap
            // entry at all — without this skip they would read as cap 0.
            guard runtime != .host else { continue }
            guard configuredRuntimes.contains(runtime) else { continue }  // validation's job
            let cap = caps[runtime] ?? 0
            guard cap == 0, seen.insert(runtime.rawValue).inserted else { continue }
            warnings.append(
                "\(runtime.rawValue) has a cap of 0 at this split — routes to it (\(routes.filter { $0.runtime == route.runtime }.count) route\(routes.filter { $0.runtime == route.runtime }.count == 1 ? "" : "s")) will never get a runner"
            )
        }
        return warnings.sorted()
    }

    /// Validation mirroring the engine's budget rules (subset of
    /// ConfigLoader's): weights in (0, 1], sum <= 1. Returns an error
    /// message or nil.
    public static func validate(_ budget: [String: Double]) -> String? {
        for (name, weight) in budget where weight <= 0 || weight > 1 {
            return "budget weight for '\(name)' must be in (0, 1], got \(weightText(weight))"
        }
        let total = budget.values.reduce(0, +)
        if total > 1.0001 {
            return String(format: "budget weights sum to %.2f — the total must be <= 1.0", total)
        }
        return nil
    }
}
