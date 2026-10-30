import Foundation
import Synchronization

/// Everything a live config reload can change about where jobs run, held as
/// ONE atomic snapshot behind a single lock: the routing model (pools and
/// routes), the per-runtime caps, the named `images:` entries, the `projects:`
/// rules and the fleet labels. A reader takes `snapshot` once and uses it for
/// a whole decision, so it never sees routes from one config and images from
/// another (the old layout kept each in its own lock).
///
/// The router is a leaf lock: nothing is called, and no other engine lock is
/// taken, while it is held (see the lock order in `FleetEngine`).
final class Router: Sendable {
    /// The reloadable routing state at one instant.
    struct Snapshot: Sendable {
        /// Label pools plus per-repo / per-workflow routes.
        var model: RuntimeConfigModel
        /// Per-runtime instance caps (empty for single-pool fleets, which
        /// keep the fleet cap).
        var caps: [RuntimeID: Int]
        /// The named `images:` entries: which labels route a job to which image.
        var images: [KinhinConfig.ImageConfig]
        /// The `projects:` rules (per-project toolchains).
        var projects: [KinhinConfig.ProjectConfig]
        /// The fleet labels forges query demand with and runners advertise.
        var labels: [String]

        /// The union of the labels every pool (and every named image) registers
        /// runners with, de-duplicated case-insensitively, in first-seen order.
        var servedLabels: [String] {
            var seen = Set<String>()
            var union: [String] = []
            let pools = model.pools.values.sorted { $0.runtime.rawValue < $1.runtime.rawValue }
            for label in pools.flatMap(\.labels) + images.flatMap({ $0.labels ?? [] })
            where seen.insert(label.lowercased()).inserted {
                union.append(label)
            }
            return union
        }

        /// The routing state `config` describes, on `host`.
        static func make(config: KinhinConfig, host: HostResources) -> Snapshot {
            Snapshot(
                model: RuntimeConfigModel(
                    config: config.runtimes,
                    fleetLabels: config.labels,
                    containerLabels: config.container?.labels,
                    containerConfigured: config.container != nil,
                    dockerConfigured: config.docker != nil,
                    dockerPlatform: config.docker?.platform ?? .arm64,
                    hostConfigured: config.hostRoutesConfigured
                ),
                // Mixed fleets partition the usable host budget between
                // runtimes; single-pool fleets keep the fleet cap.
                caps: RuntimeCapacity.caps(for: config, host: host),
                images: config.effectiveImages(),
                projects: config.projects,
                labels: config.labels)
        }

        /// Job slots the pool of `runtime` offers: its instance cap (the
        /// per-runtime partition when the fleet is mixed, else the fleet cap
        /// alone), times the runners each instance hosts.
        func jobCapacity(for runtime: RuntimeID, maxRunners: Int, capacityCap: Int, runnersPerVM: Int) -> Int {
            let instances = min(maxRunners, capacityCap, caps[runtime] ?? .max)
            return instances * max(1, runnersPerVM)
        }
    }

    private let state: Mutex<Snapshot>

    init(_ initial: Snapshot) {
        state = Mutex(initial)
    }

    /// The current state, consistent within itself.
    var snapshot: Snapshot { state.withLock { $0 } }

    /// Swaps in the state of a reloaded config.
    func replace(with snapshot: Snapshot) {
        state.withLock { $0 = snapshot }
    }
}
