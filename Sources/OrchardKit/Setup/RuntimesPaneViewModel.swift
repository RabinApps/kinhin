import Foundation

/// The Runtimes pane's read model: pools, per-runtime capacity, budget
/// shares, and routes — everything the menu bar pane renders, derived from
/// config + a host snapshot. No engine, no network, unit-testable. Health
/// probes are opt-in (`loadHealth: true`) so pure math stays synchronous.
public struct RuntimesPaneViewModel: Sendable, Equatable {
    public struct PoolRow: Sendable, Equatable {
        public let runtime: RuntimeID
        /// Labels the pool's runners register with (for `runs-on:` guidance).
        public let labels: [String]
        /// Cap implied by the host partition ("n/a" shown when unpartitioned).
        public let cap: Int?
        /// Host-budget share in percent (nil when no budget is configured).
        public let budgetPercent: Double?
        /// Live probe result (nil when not probed).
        public let health: RuntimeHealth?
    }

    public struct RouteRow: Sendable, Equatable {
        public let pattern: String
        public let runtime: RuntimeID
        /// True for `owner/name@Workflow` patterns.
        public let isWorkflow: Bool
    }

    /// Runtime pools that can serve jobs (empty until loaded).
    public var pools: [PoolRow]
    /// Configured routes in config order.
    public var routes: [RouteRow]
    /// The runtime unmatched jobs land on.
    public var defaultRuntime: RuntimeID
    /// True when a `runtimes:` section exists (vs. legacy single-pool fleet).
    public var routingConfigured: Bool
    /// The runtime a container-only fleet uses (single-pool legacy mode).
    public var containerConfigured: Bool

    public init(pools: [PoolRow] = [], routes: [RouteRow] = [], defaultRuntime: RuntimeID = .tart, routingConfigured: Bool = false, containerConfigured: Bool = false) {
        self.pools = pools
        self.routes = routes
        self.defaultRuntime = defaultRuntime
        self.routingConfigured = routingConfigured
        self.containerConfigured = containerConfigured
    }

    // MARK: Loading

    /// Build the read model from config text. With `loadHealth: true`, each
    /// pool's runtime is probed (concurrently) and the result attached to
    /// its row; probe injection keeps tests hermetic. A probe failure never
    /// blocks the pane — it just leaves that pool unprobed.
    public static func load(
        configYAML: String,
        host: HostResources,
        reserve: OrchardConfig.Reserve,
        loadHealth: Bool = false,
        tartHealth: (@Sendable () async -> RuntimeHealth)? = nil,
        containerHealth: (@Sendable () async -> RuntimeHealth)? = nil
    ) async -> RuntimesPaneViewModel {
        var vm = RuntimesPaneViewModel()
        guard let parsed = try? ConfigLoader.parse(configYAML) else { return vm }

        vm.containerConfigured = parsed.container != nil
        let routing = (try? RuntimesConfigEditor.parsed(from: configYAML)) ?? nil
        let rc = routing ?? parsed.runtimes
        vm.routingConfigured = rc != nil
        let fleetLabels = parsed.labels

        // Pools: same construction the engine uses (RuntimeConfigModel), so
        // the pane never disagrees with what the fleet actually registers.
        let model = RuntimeConfigModel(
            config: rc,
            fleetLabels: fleetLabels,
            containerLabels: parsed.container?.labels,
            containerConfigured: vm.containerConfigured
        )

        // Capacity: partition math identical to the engine's init.
        var caps: [RuntimeID: Int] = [:]
        if let rc {
            let partition = RuntimeCapacity.partition(
                hostUsableCPU: max(0, host.logicalCores - reserve.cpu),
                hostUsableMemoryGB: max(0, host.memoryGB - reserve.memoryGB),
                weights: rc.budget,
                defaultRuntime: RuntimeID(rawValue: rc.defaultRuntime) ?? .tart,
                shape: { id in
                    id == .appleContainer
                        ? (parsed.container?.cpus ?? 4, parsed.container?.memoryGB ?? 8)
                        : (parsed.vm.cpuCount, parsed.vm.memoryGB)
                }
            )
            caps = partition.caps
        } else {
            // Single-pool fleet: the engine's cap is the full Capacity.plan
            // on the primary runtime's shape (no partition).
            let shapeCPU = vm.containerConfigured ? (parsed.container?.cpus ?? 4) : parsed.vm.cpuCount
            let shapeMem = vm.containerConfigured ? (parsed.container?.memoryGB ?? 8) : parsed.vm.memoryGB
            let primary: RuntimeID = vm.containerConfigured ? .appleContainer : .tart
            caps[primary] = Capacity.plan(
                host: host,
                vmCPU: shapeCPU,
                vmMemoryGB: shapeMem,
                reservedCPU: reserve.cpu,
                reservedMemoryGB: reserve.memoryGB,
                diskPerVMGB: parsed.diskGB ?? 0,
                userMax: parsed.maxRunners
            ).maxConcurrent
        }

        // Health probes: one per pool, concurrently.
        var healths: [RuntimeID: RuntimeHealth] = [:]
        if loadHealth {
            healths = await probeHealth(parsed: parsed, poolIDs: Set(model.pools.keys), tartHealth: tartHealth, containerHealth: containerHealth)
        }

        vm.pools = model.pools.keys.sorted { $0.rawValue < $1.rawValue }.map { id in
            let pool = model.pools[id]!
            return PoolRow(
                runtime: id,
                labels: pool.labels,
                cap: caps[id],
                budgetPercent: rc?.budget[id.rawValue].map { $0 * 100 },
                health: healths[id]
            )
        }
        vm.defaultRuntime = model.defaultRuntime
        vm.routes = (rc?.routes ?? []).map { route in
            RouteRow(
                pattern: route.pattern,
                runtime: RuntimeID(rawValue: route.runtime) ?? .tart,
                isWorkflow: route.pattern.contains("@")
            )
        }
        return vm
    }

    /// Probe each pool's runtime. Real probes by default; injectable for tests.
    static func probeHealth(
        parsed: OrchardConfig,
        poolIDs: Set<RuntimeID>,
        tartHealth: (@Sendable () async -> RuntimeHealth)?,
        containerHealth: (@Sendable () async -> RuntimeHealth)?
    ) async -> [RuntimeID: RuntimeHealth] {
        await withTaskGroup(of: (RuntimeID, RuntimeHealth?).self) { group in
            if poolIDs.contains(.tart) {
                if let injected = tartHealth {
                    group.addTask { (.tart, await injected()) }
                } else if let controller = try? TartController(configuredPath: parsed.tartPath) {
                    let runtime = TartRuntime(tart: controller, bootTimeout: { parsed.vmBootTimeout })
                    group.addTask { (.tart, await runtime.health()) }
                } else {
                    // Controller construction fails when the binary is
                    // missing — that IS the health answer, not a probe error.
                    group.addTask { (.tart, RuntimeHealth.missing(tool: "tart", fix: "brew tap openai/tools && brew trust openai/tools && brew install openai/tools/tart")) }
                }
            }
            if poolIDs.contains(.appleContainer), parsed.container != nil {
                if let injected = containerHealth {
                    group.addTask { (.appleContainer, await injected()) }
                } else {
                    let runtime = AppleContainerRuntime(
                        image: parsed.container?.image ?? "orchard-ci-linux",
                        cpus: parsed.container?.cpus ?? 4,
                        memoryGB: parsed.container?.memoryGB ?? 8
                    )
                    group.addTask { (.appleContainer, await runtime.health()) }
                }
            }
            var results: [RuntimeID: RuntimeHealth] = [:]
            for await (id, health) in group {
                if let health { results[id] = health }
            }
            return results
        }
    }

    /// One-line human summary for a probe result (nil → nothing to show).
    public static func healthNote(for health: RuntimeHealth?) -> String? {
        switch health {
        case nil, .ready:
            return nil
        case .missing(let tool, let fix):
            return "\(tool): not installed — \(fix)"
        case .broken(let why):
            return why
        }
    }
}
