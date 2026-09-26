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
    /// True when a `docker:` section exists (Docker slot pool).
    var dockerConfigured: Bool
    /// Every execution runtime this Mac could ever use, probed or not —
    /// so the pane can say "installed" / "not installed" even for runtimes
    /// the config doesn't use. Empty until a health pass fills it.
    public var availability: [RuntimeID: RuntimeHealth] = [:]

    public init(
        pools: [PoolRow] = [], routes: [RouteRow] = [], defaultRuntime: RuntimeID = .tart,
        routingConfigured: Bool = false, containerConfigured: Bool = false, dockerConfigured: Bool = false,
        availability: [RuntimeID: RuntimeHealth] = [:]
    ) {
        self.pools = pools
        self.routes = routes
        self.defaultRuntime = defaultRuntime
        self.routingConfigured = routingConfigured
        self.containerConfigured = containerConfigured
        self.dockerConfigured = dockerConfigured
        self.availability = availability
    }

    // MARK: Loading

    /// Build the read model from config text. With `loadHealth: true`, each
    /// pool's runtime is probed (concurrently) and the result attached to
    /// its row; probe injection keeps tests hermetic. A probe failure never
    /// blocks the pane — it just leaves that pool unprobed.
    public static func load(
        configYAML: String,
        host: HostResources,
        reserve: KinhinConfig.Reserve,
        loadHealth: Bool = false,
        tartHealth: (@Sendable () async -> RuntimeHealth)? = nil,
        containerHealth: (@Sendable () async -> RuntimeHealth)? = nil
    ) async -> RuntimesPaneViewModel {
        var vm = RuntimesPaneViewModel()
        let parsed: KinhinConfig
        do {
            parsed = try ConfigLoader.parse(configYAML)
        } catch {
            Log.warn("runtimes", "config could not be parsed for the pane: \(error.localizedDescription)")
            return vm
        }

        vm.containerConfigured = parsed.container != nil
        vm.dockerConfigured = parsed.docker != nil
        let routing: KinhinConfig.RuntimeConfig?
        do {
            routing = try RuntimesConfigEditor.parsed(from: configYAML)
        } catch {
            Log.warn("runtimes", "routing section could not be read: \(error.localizedDescription)")
            routing = nil
        }
        let rc = routing ?? parsed.runtimes
        vm.routingConfigured = rc != nil
        let fleetLabels = parsed.labels

        // Pools: same construction the engine uses (RuntimeConfigModel), so
        // the pane never disagrees with what the fleet actually registers.
        let hostConfigured = parsed.hostRoutesConfigured
        let model = RuntimeConfigModel(
            config: rc,
            fleetLabels: fleetLabels,
            containerLabels: parsed.container?.labels,
            containerConfigured: vm.containerConfigured,
            dockerConfigured: vm.dockerConfigured,
            dockerPlatform: parsed.docker?.platform ?? .arm64,
            hostConfigured: hostConfigured
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
                    switch id {
                    case .appleContainer:
                        return (parsed.container?.cpus ?? 4, parsed.container?.memoryGB ?? 8)
                    case .docker:
                        return (parsed.docker?.cpus ?? 2, parsed.docker?.memoryGB ?? 4)
                    case .host:
                        return (1, 1)
                    default:
                        return (parsed.vm.cpuCount, parsed.vm.memoryGB)
                    }
                }
            )
            caps = partition.caps
            if let dockerConfig = parsed.docker, let partitionCap = caps[.docker] {
                caps[.docker] = min(partitionCap, dockerConfig.maxSlots)
            }
        } else {
            // Single-pool fleet: the engine's cap is the full Capacity.plan
            // on the primary runtime's shape (no partition).
            let primary: RuntimeID = vm.containerConfigured ? .appleContainer : (vm.dockerConfigured ? .docker : .tart)
            let (shapeCPU, shapeMem): (Int, Int)
            switch primary {
            case .appleContainer:
                (shapeCPU, shapeMem) = (parsed.container?.cpus ?? 4, parsed.container?.memoryGB ?? 8)
            case .docker:
                (shapeCPU, shapeMem) = (parsed.docker?.cpus ?? 2, parsed.docker?.memoryGB ?? 4)
            default:
                (shapeCPU, shapeMem) = (parsed.vm.cpuCount, parsed.vm.memoryGB)
            }
            caps[primary] =
                Capacity.plan(
                    host: host,
                    vmCPU: shapeCPU,
                    vmMemoryGB: shapeMem,
                    reservedCPU: reserve.cpu,
                    reservedMemoryGB: reserve.memoryGB,
                    diskPerVMGB: parsed.diskGB ?? 0,
                    userMax: parsed.maxRunners
                ).maxConcurrent
        }

        // Health probes: one per pool, concurrently — plus a full
        // availability sweep so the pane can show installed / not installed
        // for every runtime this Mac could use, configured or not.
        var healths: [RuntimeID: RuntimeHealth] = [:]
        if loadHealth {
            healths = await probeHealth(
                parsed: parsed, poolIDs: Set(model.pools.keys), tartHealth: tartHealth, containerHealth: containerHealth
            )
            vm.availability = await probeAvailability(
                parsed: parsed,
                tartHealth: tartHealth,
                containerHealth: containerHealth
            )
        }

        vm.pools = model.pools.sorted { $0.key.rawValue < $1.key.rawValue }.map { id, pool in
            PoolRow(
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

    /// Probe every executable runtime (tart, apple container, docker) —
    /// configured or not — so the UI can answer "what's installed on this
    /// Mac?". Real probes by default; the same injection points as
    /// `probeHealth` keep tests hermetic.
    static func probeAvailability(
        parsed: KinhinConfig,
        tartHealth: (@Sendable () async -> RuntimeHealth)?,
        containerHealth: (@Sendable () async -> RuntimeHealth)?
    ) async -> [RuntimeID: RuntimeHealth] {
        await withTaskGroup(of: (RuntimeID, RuntimeHealth).self) { group in
            if let injected = tartHealth {
                group.addTask { (.tart, await injected()) }
            } else if let controller = try? TartController(configuredPath: parsed.tartPath) {
                let runtime = TartRuntime(tart: controller, bootTimeout: { parsed.vmBootTimeout })
                group.addTask { (.tart, await runtime.health()) }
            } else {
                // Construction fails only when the binary is missing, which is the answer.
                group.addTask {
                    (
                        .tart,
                        RuntimeHealth.missing(
                            tool: "tart",
                            fix: "brew tap openai/tools && brew trust openai/tools && brew install openai/tools/tart")
                    )
                }
            }

            if let injected = containerHealth {
                group.addTask { (.appleContainer, await injected()) }
            } else {
                let runtime = AppleContainerRuntime(
                    image: parsed.container?.image ?? "kinhin-ci-linux",
                    cpus: parsed.container?.cpus ?? 4,
                    memoryGB: parsed.container?.memoryGB ?? 8
                )
                group.addTask { (.appleContainer, await runtime.health()) }
            }

            let docker = DockerRuntime(
                image: parsed.docker?.image ?? "kinhin-ci-linux",
                cpus: parsed.docker?.cpus ?? 2,
                memoryGB: parsed.docker?.memoryGB ?? 4
            )
            group.addTask { (.docker, await docker.health()) }

            var results: [RuntimeID: RuntimeHealth] = [:]
            for await (id, health) in group {
                results[id] = health
            }
            return results
        }
    }

    /// Probe each pool's runtime. Real probes by default; injectable for tests.
    static func probeHealth(
        parsed: KinhinConfig,
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
                    group.addTask {
                        (
                            .tart,
                            RuntimeHealth.missing(
                                tool: "tart",
                                fix:
                                    "brew tap openai/tools && brew trust openai/tools && brew install openai/tools/tart"
                            )
                        )
                    }
                }
            }
            if poolIDs.contains(.appleContainer), parsed.container != nil {
                if let injected = containerHealth {
                    group.addTask { (.appleContainer, await injected()) }
                } else {
                    let runtime = AppleContainerRuntime(
                        image: parsed.container?.image ?? "kinhin-ci-linux",
                        cpus: parsed.container?.cpus ?? 4,
                        memoryGB: parsed.container?.memoryGB ?? 8
                    )
                    group.addTask { (.appleContainer, await runtime.health()) }
                }
            }
            if poolIDs.contains(.docker), parsed.docker != nil {
                let runtime = DockerRuntime(
                    image: parsed.docker?.image ?? "kinhin-ci-linux",
                    cpus: parsed.docker?.cpus ?? 2,
                    memoryGB: parsed.docker?.memoryGB ?? 4
                )
                group.addTask { (.docker, await runtime.health()) }
            }
            if poolIDs.contains(.host) {
                group.addTask { (.host, await HostRuntime().health()) }
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
