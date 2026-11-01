import Foundation

/// Which named `container.pools:` entry serves a job the runtime router sent to Apple container, and the labels each
/// pool's runners register with. The rule is the one named Tart `images:` follow (`ImageRouting`), plus explicit
/// targeting:
///
/// 1. A job that carries a pool's own marker (`runs-on: [..., kinhin-container-big]`) runs there.
/// 2. Else, among the pools of the architecture the job asks for (`x64` or `arm64` in its labels; every pool when it
///    names neither), the most specific one whose labels the job carries all of (case-insensitive, as the forges
///    compare them): the most labels wins, then the first by name.
/// 3. Else the default pool (`ContainerConfig.defaultPool`: the fewest labels, then the first by name), or, when that
///    one runs the other architecture, the same choice among the pools of the job's.
///
/// Empty for a section without `pools:`: its one pool keeps exactly the labels and routing it had before pools.
struct ContainerPoolRouting: Sendable, Equatable {
    /// One named pool as routing sees it.
    struct Entry: Sendable, Equatable {
        let name: String
        /// The pool's own `labels:`: what a job must carry for rule 2.
        let ownLabels: [String]
        /// Every label the pool's runners register with: the base labels (`RuntimePool.labelsFor`, honouring the
        /// pool's `fleet_labels` and swapping `arm64` for `x64` on an amd64 pool), its own, `kinhin-container` and
        /// `kinhin-container-<name>`, in that order.
        let labels: [String]
        /// The architecture the pool's runners run.
        let platform: LinuxPlatform

        /// The label that targets this pool alone (rule 1).
        var marker: String { KinhinConfig.ContainerConfig.Pool.marker(forName: name) }
    }

    /// The named pools, sorted by name; empty without `pools:`.
    let entries: [Entry]
    /// The default pool's name ("" when `entries` is empty).
    let defaultName: String

    static let none = ContainerPoolRouting(entries: [], defaultName: "")

    private init(entries: [Entry], defaultName: String) {
        self.entries = entries
        self.defaultName = defaultName
    }

    /// The table for `pools` (a section's named pools; none for a section without `pools:`) on a fleet labelled
    /// `fleetLabels`. `honoursFleetLabels` is false on a fleet without a `runtimes:` section, whose one runtime
    /// always registers with the fleet labels (`fleet_labels:` only splits pools of a mixed fleet), as before pools.
    init(pools: [KinhinConfig.ContainerConfig.Pool], fleetLabels: [String], honoursFleetLabels: Bool = true) {
        let named = pools.filter(\.isNamed).sorted { $0.name < $1.name }
        self.entries = named.map { pool in
            var labels = RuntimePool.labelsFor(
                .appleContainer, fleetLabels: fleetLabels, containerExtra: pool.labels,
                containerPlatform: pool.platform,
                inheritingFleetLabels: honoursFleetLabels ? pool.fleetLabels ?? true : true)
            if let marker = pool.marker, !labels.contains(marker) { labels.append(marker) }
            return Entry(name: pool.name, ownLabels: pool.labels ?? [], labels: labels, platform: pool.platform)
        }
        self.defaultName = KinhinConfig.ContainerConfig.defaultPool(of: named)?.name ?? ""
    }

    var isEmpty: Bool { entries.isEmpty }

    /// The pool `name` resolves to: that pool, else the default one (a record without a pool, or from a pool since
    /// removed). Nil only when the table is empty.
    func entry(named name: String?) -> Entry? {
        entries.first { $0.name == name } ?? entries.first { $0.name == defaultName }
    }

    /// The pool a job targets by its marker (rule 1), if any.
    func explicitPool(for jobLabels: [String]?) -> Entry? {
        let requested = Set((jobLabels ?? []).map { $0.lowercased() })
        return entries.first { requested.contains($0.marker) }
    }

    /// The pool that serves a job with `jobLabels` (rules 1 to 3). Nil only when the table is empty.
    func pool(for jobLabels: [String]?) -> Entry? {
        if let explicit = explicitPool(for: jobLabels) { return explicit }
        let requested = Set((jobLabels ?? []).map { $0.lowercased() })
        let wanted = Self.requestedPlatform(requested)
        let candidates = entries.filter { wanted == nil || $0.platform == wanted }
        var best: Entry?
        for entry in candidates where !entry.ownLabels.isEmpty {
            guard Set(entry.ownLabels.map { $0.lowercased() }).isSubset(of: requested) else { continue }
            if best == nil || entry.ownLabels.count > (best?.ownLabels.count ?? 0) { best = entry }
        }
        if let best { return best }
        if let fallback = candidates.first(where: { $0.name == defaultName }) { return fallback }
        let ofJobsPlatform = candidates.min { ($0.ownLabels.count, $0.name) < ($1.ownLabels.count, $1.name) }
        return ofJobsPlatform ?? entry(named: defaultName)
    }

    /// The architecture a job asks for by label: `x64` or `arm64` (lowercased `labels`), nil when it names neither or
    /// both (no runner carries both, so neither narrows the choice).
    static func requestedPlatform(_ labels: Set<String>) -> LinuxPlatform? {
        let x64 = labels.contains(LinuxPlatform.amd64.runnerLabel)
        let arm64 = labels.contains(LinuxPlatform.arm64.runnerLabel)
        if x64 == arm64 { return nil }
        return x64 ? .amd64 : .arm64
    }
}
