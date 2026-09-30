import Foundation

/// Pure math for the Runtimes pane's budget editing: slider drags map to
/// validated `budget` dictionaries, the default-runtime remainder rule is
/// applied consistently, and round-trips through config text are tested.
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

    /// A single slider drag: set `runtime`'s weight (0...1 of the *whole*
    /// budget) and scale every non-default runtime proportionally so their
    /// shares stay consistent. The default runtime receives whatever
    /// remains — never below zero, never above 1.
    public static func setShare(
        of runtime: RuntimeID,
        to fraction: Double,
        current: [String: Double],
        defaultRuntime: RuntimeID
    ) -> [String: Double] {
        var result: [String: Double] = current
        let target = clamp(fraction)
        let others = current.keys.filter { $0 != runtime.rawValue && $0 != defaultRuntime.rawValue }

        // Other non-default weights scale to fill the vacated share.
        let oldTarget = current[runtime.rawValue] ?? 0
        let otherTotal = others.reduce(0) { $0 + (current[$1] ?? 0) }
        let vacated = max(0, oldTarget - target)
        for key in others {
            let old = current[key] ?? 0
            let scaled = otherTotal > 0 ? old + vacated * (old / otherTotal) : old
            result[key] = clamp(scaled)
        }
        result[runtime.rawValue] = target

        // The default takes the remainder; drop it from the dict when there
        // is none (absence = "whatever's left" = 0 here).
        let nonDefault = result.filter { $0.key != defaultRuntime.rawValue }
        let remainder = clamp(1 - nonDefault.values.reduce(0, +))
        result[defaultRuntime.rawValue] = remainder > 0 ? remainder : 0
        return result
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
        // The default keeps the remainder, same rule as setShare.
        let nonDefault = result.filter { $0.key != defaultRuntime.rawValue }
        let remainder = clamp(1 - nonDefault.values.reduce(0, +))
        result[defaultRuntime.rawValue] = remainder > 0 ? remainder : 0
        return result
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
            guard let runtime = RuntimeID(rawValue: route.runtime) else { continue }
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
