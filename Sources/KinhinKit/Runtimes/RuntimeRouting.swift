import Foundation

// MARK: - Runtime pools

/// One label pool: a runtime whose runners register with distinct labels so
/// workflows route per job via `runs-on:`. Pools are built from the config
/// (`runtimes:` section when present, or the legacy single-fleet defaults).
struct RuntimePool: Sendable, Equatable {
    /// The execution runtime backing this pool.
    let runtime: RuntimeID
    /// Labels the pool's runners register with (fleet labels + runtime marker).
    let labels: [String]

    init(runtime: RuntimeID, labels: [String]) {
        self.runtime = runtime
        self.labels = labels
    }

    /// The fleet's default label set for this runtime: the config labels
    /// plus the runtime's marker ("kinhin-container" for Apple containers,
    /// "kinhin-docker" for Docker slots).
    static func labelsFor(
        _ runtime: RuntimeID, fleetLabels: [String], containerExtra: [String]? = nil,
        dockerPlatform: LinuxPlatform = .arm64
    ) -> [String] {
        var labels = fleetLabels
        // Emulated amd64 containers must not advertise the fleet's native
        // `arm64` label: swap it for `x64` so jobs land on the right architecture.
        if runtime == .docker, dockerPlatform == .amd64 {
            labels.removeAll { $0.lowercased() == LinuxPlatform.arm64.runnerLabel }
            if !labels.contains(where: { $0.lowercased() == dockerPlatform.runnerLabel }) {
                labels.append(dockerPlatform.runnerLabel)
            }
        }
        if let marker = exclusiveMarker(for: runtime) {
            if !labels.contains(marker) { labels.append(marker) }
        }
        if runtime == .appleContainer {
            for extra in containerExtra ?? [] where !labels.contains(extra) {
                labels.append(extra)
            }
        }
        return labels
    }

    /// The exclusive `runs-on:` marker a pool registers with, enabling
    /// per-workflow opt-in without a config route. nil for runtimes that
    /// serve the fleet's default labels (tart). Host mode always marks:
    /// only explicitly opted-in workflows may run unisolated on the Mac.
    static func exclusiveMarker(for runtime: RuntimeID) -> String? {
        switch runtime {
        case .appleContainer: return "kinhin-container"
        case .docker: return "kinhin-docker"
        case .host: return "kinhin-host"
        default: return nil
        }
    }
}

/// Resolves a queued job to the pool that should serve it. Precedence:
/// 0. The forge's own choice (`ForgeJob.runtimeHint`, scale-set jobs).
/// 1. Workflow route (`owner/name@Workflow`) — most specific.
/// 2. Repo route (`owner/name`).
/// 3. Label capability: a job whose labels include a pool's exclusive
///    marker ("kinhin-container") routes to that pool even without a
///    config route (per-workflow `runs-on:` opt-in).
/// 4. The default runtime for unmatched jobs.
enum RuntimeRouter {
    struct Decision: Sendable, Equatable {
        let pool: RuntimePool
        /// How the pool was chosen (for logs and tests).
        let via: String

        init(pool: RuntimePool, via: String) {
            self.pool = pool
            self.via = via
        }
    }

    /// Extract "owner/name" from a job's repository field (nil-safe).
    static func repoKey(_ repo: String?) -> String? {
        guard let repo, !repo.isEmpty else { return nil }
        return repo
    }

    /// Extract the workflow name from a job. GitHub's queued-jobs search
    /// returns job names as "workflow / job"; the workflow portion is the
    /// leading segment. Jobs without a separator use the full name.
    static func workflowKey(from job: ForgeJob) -> String? {
        guard !job.name.isEmpty else { return nil }
        if let sep = job.name.range(of: " / ") {
            return String(job.name[..<sep.lowerBound]).trimmingCharacters(in: .whitespaces)
        }
        return job.name
    }

    /// The workflow name portion of a route pattern, if any.
    static func workflow(of pattern: String) -> String? {
        guard pattern.contains("@"), !pattern.hasSuffix("@") else { return nil }
        return String(pattern.split(separator: "@", maxSplits: 1).last ?? "")
    }

    /// The repo portion of a route pattern ("owner/name@Workflow" → "owner/name").
    static func repoPattern(of pattern: String) -> String {
        String(pattern.split(separator: "@", maxSplits: 1).first ?? "")
    }

    /// Route a queued job to a pool.
    static func assign(
        job: ForgeJob, config: RuntimeConfigModel, defaultPool: RuntimePool, pools: [RuntimeID: RuntimePool]
    ) -> Decision {
        // 0. The forge already chose (scale-set jobs: the set the workflow named).
        if let hint = job.runtimeHint, let pool = pools[hint] {
            return Decision(pool: pool, via: "scale-set:\(hint.rawValue)")
        }
        let repo = repoKey(job.repository)

        // 1 & 2. Workflow-then-repo route precedence.
        if let repo {
            // Workflow routes first ("owner/name@Workflow"). GitHub job names
            // arrive as "Workflow / job", so the workflow key is the leading
            // segment; a plain name also matches by equality (case-insensitive).
            let workflowName = workflowKey(from: job)
            for route in config.routes {
                guard let routeWorkflow = workflow(of: route.pattern) else { continue }
                guard repoPattern(of: route.pattern) == repo else { continue }
                if let workflowName,
                    workflowName.caseInsensitiveCompare(routeWorkflow) == .orderedSame
                {
                    if let pool = pools[route.runtime] {
                        return Decision(pool: pool, via: "workflow:\(route.pattern)")
                    }
                }
            }
            for route in config.routes where workflow(of: route.pattern) == nil {
                if repoPattern(of: route.pattern) == repo {
                    if let pool = pools[route.runtime] {
                        return Decision(pool: pool, via: "repo:\(route.pattern)")
                    }
                }
            }
        }

        // 3. Label opt-in: jobs requesting a pool's exclusive marker go there
        // (kinhin-container for Apple containers, kinhin-docker for Docker).
        for (runtimeID, pool) in pools.sorted(by: { $0.key.rawValue < $1.key.rawValue }) {
            if let marker = RuntimePool.exclusiveMarker(for: runtimeID),
                pool.labels.contains(marker),
                Set(job.labels ?? []).contains(marker)
            {
                return Decision(pool: pool, via: "label:\(marker)")
            }
        }

        // 4. Default.
        return Decision(pool: defaultPool, via: "default")
    }
}

/// The engine-facing routing model: pools by runtime id plus the config
/// routes, with demand bucketing and spawn selection. Public so the CLI can
/// pre-flight against exactly the table the engine routes with.
public struct RuntimeConfigModel: Sendable {
    let routes: [KinhinConfig.RuntimeConfig.Route]
    let pools: [RuntimeID: RuntimePool]
    let defaultRuntime: RuntimeID

    init(
        config: KinhinConfig.RuntimeConfig?, fleetLabels: [String], containerLabels: [String]? = nil,
        containerConfigured: Bool = false, dockerConfigured: Bool = false, dockerPlatform: LinuxPlatform = .arm64,
        hostConfigured: Bool = false
    ) {
        if let config {
            // Explicit routing: tart is always available (macOS workloads),
            // containers and Docker slots join when configured. The default
            // runtime comes from the config.
            self.routes = config.routes
            self.defaultRuntime = config.defaultRuntime
            var pools: [RuntimeID: RuntimePool] = [:]
            pools[.tart] = RuntimePool(runtime: .tart, labels: RuntimePool.labelsFor(.tart, fleetLabels: fleetLabels))
            if containerConfigured {
                pools[.appleContainer] = RuntimePool(
                    runtime: .appleContainer,
                    labels: RuntimePool.labelsFor(
                        .appleContainer, fleetLabels: fleetLabels, containerExtra: containerLabels)
                )
            }
            if dockerConfigured {
                pools[.docker] = RuntimePool(
                    runtime: .docker,
                    labels: RuntimePool.labelsFor(.docker, fleetLabels: fleetLabels, dockerPlatform: dockerPlatform)
                )
            }
            if hostConfigured {
                pools[.host] = RuntimePool(
                    runtime: .host, labels: RuntimePool.labelsFor(.host, fleetLabels: fleetLabels))
            }
            self.pools = pools
        } else {
            // No routing config: the fleet is a single pool on its primary
            // runtime — containers when configured (the established Linux
            // path), else Docker slots, else tart. Exactly the pre-routing
            // behavior when only tart/container exist.
            let primary: RuntimeID = containerConfigured ? .appleContainer : (dockerConfigured ? .docker : .tart)
            self.routes = []
            self.defaultRuntime = primary
            self.pools = [
                primary: RuntimePool(
                    runtime: primary,
                    labels: RuntimePool.labelsFor(
                        primary, fleetLabels: fleetLabels, containerExtra: containerLabels,
                        dockerPlatform: dockerPlatform)
                )
            ]
        }
    }

    /// Bucket queued jobs into per-pool demand counts.
    func demandByPool(for jobs: [ForgeJob], forgeID: ForgeID) -> [RuntimeID: Int] {
        var counts: [RuntimeID: Int] = [:]
        let defaultPool = pools[defaultRuntime] ?? RuntimePool(runtime: .tart, labels: [])
        for job in jobs {
            let decision = RuntimeRouter.assign(job: job, config: self, defaultPool: defaultPool, pools: pools)
            counts[decision.pool.runtime, default: 0] += 1
        }
        return counts
    }

    /// The runtime whose pool a queued job routes to.
    func runtime(for job: ForgeJob) -> RuntimeID {
        let defaultPool = pools[defaultRuntime] ?? RuntimePool(runtime: .tart, labels: [])
        return RuntimeRouter.assign(job: job, config: self, defaultPool: defaultPool, pools: pools).pool.runtime
    }

    /// True when the pool exists (its runtime is configured).
    func poolExists(_ runtime: RuntimeID) -> Bool {
        pools[runtime] != nil
    }
}

public extension RuntimeConfigModel {
    /// The labels the pool for `runtime` registers with under `config`, or nil
    /// when the fleet has no such pool. Built exactly as `FleetEngine` builds
    /// its table, so a pre-flight check (the CLI's `workflow route`) never
    /// disagrees with what the engine can actually serve.
    ///
    /// `host` is answered as if the route that opts it in already exists:
    /// the host pool joins the fleet only when a host route does, and callers
    /// gate that route on consent before asking.
    static func poolLabels(for runtime: RuntimeID, config: KinhinConfig) -> [String]? {
        // Host joins only through a consented route (gated before this call),
        // and a single-pool fleet never builds a host pool on its own — its
        // labels are the fleet labels plus the marker either way, exactly as
        // `RuntimePool.labelsFor` builds them once the route exists.
        if runtime == .host { return RuntimePool.labelsFor(.host, fleetLabels: config.labels) }
        let model = RuntimeConfigModel(
            config: config.runtimes,
            fleetLabels: config.labels,
            containerLabels: config.container?.labels,
            containerConfigured: config.container != nil,
            dockerConfigured: config.docker != nil,
            dockerPlatform: config.docker?.platform ?? .arm64,
            hostConfigured: config.hostRoutesConfigured
        )
        return model.pools[runtime]?.labels
    }
}

// MARK: - Weighted capacity partition

/// Splits the host's usable budget between runtimes by configured weights.
/// The default runtime receives the remainder when weights sum below 1.
enum RuntimeCapacity {
    struct Partition: Sendable, Equatable {
        /// Per-runtime caps (in VMs/containers of that runtime's shape).
        let caps: [RuntimeID: Int]
        /// Human summary for status/doctor lines.
        let summary: String
    }

    static func partition(
        hostUsableCPU: Int,
        hostUsableMemoryGB: Int,
        weights: [String: Double],
        defaultRuntime: RuntimeID,
        shape: (RuntimeID) -> (cpu: Int, memoryGB: Int)
    ) -> Partition {
        var caps: [RuntimeID: Int] = [:]
        var allocatedCPU = 0
        var allocatedMem = 0

        for (name, weight) in weights.sorted(by: { $0.key < $1.key }) {
            guard let runtime = RuntimeID(rawValue: name), name != defaultRuntime.rawValue else { continue }
            let cpuShare = Int((Double(hostUsableCPU) * weight).rounded(.down))
            let memShare = Int((Double(hostUsableMemoryGB) * weight).rounded(.down))
            let shapeFor = shape(runtime)
            let cap =
                shapeFor.cpu > 0
                ? min(
                    shapeFor.cpu > 0 ? cpuShare / shapeFor.cpu : 0,
                    shapeFor.memoryGB > 0 ? memShare / shapeFor.memoryGB : Int.max
                ) : 0
            caps[runtime] = max(0, cap)
            allocatedCPU += cpuShare
            allocatedMem += memShare
        }

        // Default runtime gets the remainder.
        let restCPU = max(0, hostUsableCPU - allocatedCPU)
        let restMem = max(0, hostUsableMemoryGB - allocatedMem)
        let defShape = shape(defaultRuntime)
        let defCap =
            defShape.cpu > 0
            ? min(
                restCPU / defShape.cpu,
                defShape.memoryGB > 0 ? restMem / defShape.memoryGB : Int.max
            ) : 0
        caps[defaultRuntime] = max(0, defCap)

        let summary = caps.keys.sorted { $0.rawValue < $1.rawValue }
            .map { "\($0.rawValue): \(caps[$0] ?? 0)" }
            .joined(separator: " · ")
        return Partition(caps: caps, summary: summary.isEmpty ? "none" : summary)
    }
}
