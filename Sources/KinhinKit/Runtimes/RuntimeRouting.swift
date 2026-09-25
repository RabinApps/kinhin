import Foundation

// MARK: - Runtime pools

/// One label pool: a runtime whose runners register with distinct labels so
/// workflows route per job via `runs-on:`. Pools are built from the config
/// (`runtimes:` section when present, or the legacy single-fleet defaults).
public struct RuntimePool: Sendable, Equatable {
    /// The execution runtime backing this pool.
    public let runtime: RuntimeID
    /// Labels the pool's runners register with (fleet labels + runtime marker).
    public let labels: [String]

    public init(runtime: RuntimeID, labels: [String]) {
        self.runtime = runtime
        self.labels = labels
    }

    /// The fleet's default label set for this runtime: the config labels
    /// plus the runtime's marker ("kinhin-container" for Apple containers,
    /// "kinhin-docker" for Docker slots).
    public static func labelsFor(_ runtime: RuntimeID, fleetLabels: [String], containerExtra: [String]? = nil)
        -> [String]
    {
        var labels = fleetLabels
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
    /// serve the fleet's default labels (tart).
    public static func exclusiveMarker(for runtime: RuntimeID) -> String? {
        switch runtime {
        case .appleContainer: return "kinhin-container"
        case .docker: return "kinhin-docker"
        default: return nil
        }
    }
}

/// Resolves a queued job to the pool that should serve it. Precedence:
/// 1. Workflow route (`RabinApps/name@Workflow`) — most specific.
/// 2. Repo route (`RabinApps/name`).
/// 3. Label capability: a job whose labels include a pool's exclusive
///    marker ("kinhin-container") routes to that pool even without a
///    config route (per-workflow `runs-on:` opt-in).
/// 4. The default runtime for unmatched jobs.
public enum RuntimeRouter {
    public struct Decision: Sendable, Equatable {
        public let pool: RuntimePool
        /// How the pool was chosen (for logs and tests).
        public let via: String

        public init(pool: RuntimePool, via: String) {
            self.pool = pool
            self.via = via
        }
    }

    /// Extract "RabinApps/name" from a job's repository field (nil-safe).
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

    /// The repo portion of a route pattern ("RabinApps/name@Workflow" → "RabinApps/name").
    static func repoPattern(of pattern: String) -> String {
        String(pattern.split(separator: "@", maxSplits: 1).first ?? "")
    }

    /// Route a queued job to a pool.
    public static func assign(
        job: ForgeJob, config: RuntimeConfigModel, defaultPool: RuntimePool, pools: [RuntimeID: RuntimePool]
    ) -> Decision {
        let repo = repoKey(job.repository)

        // 1 & 2. Workflow-then-repo route precedence.
        if let repo {
            // Workflow routes first ("RabinApps/name@Workflow"). GitHub job names
            // arrive as "Workflow / job", so the workflow key is the leading
            // segment; a plain name also matches by equality (case-insensitive).
            let workflowName = workflowKey(from: job)
            for route in config.routes {
                guard let routeWorkflow = workflow(of: route.pattern) else { continue }
                guard repoPattern(of: route.pattern) == repo else { continue }
                if let workflowName,
                    workflowName.caseInsensitiveCompare(routeWorkflow) == .orderedSame
                {
                    if let pool = pools[RuntimeID(rawValue: route.runtime) ?? .tart] {
                        return Decision(pool: pool, via: "workflow:\(route.pattern)")
                    }
                }
            }
            for route in config.routes where workflow(of: route.pattern) == nil {
                if repoPattern(of: route.pattern) == repo {
                    if let pool = pools[RuntimeID(rawValue: route.runtime) ?? .tart] {
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
/// routes, with demand bucketing and spawn selection.
public struct RuntimeConfigModel: Sendable {
    public let routes: [KinhinConfig.RuntimeConfig.Route]
    public let pools: [RuntimeID: RuntimePool]
    public let defaultRuntime: RuntimeID

    public init(
        config: KinhinConfig.RuntimeConfig?, fleetLabels: [String], containerLabels: [String]? = nil,
        containerConfigured: Bool = false, dockerConfigured: Bool = false
    ) {
        if let config {
            // Explicit routing: tart is always available (macOS workloads),
            // containers and Docker slots join when configured. The default
            // runtime comes from the config.
            self.routes = config.routes
            self.defaultRuntime = RuntimeID(rawValue: config.defaultRuntime) ?? .tart
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
                    labels: RuntimePool.labelsFor(.docker, fleetLabels: fleetLabels)
                )
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
                    labels: RuntimePool.labelsFor(primary, fleetLabels: fleetLabels, containerExtra: containerLabels)
                )
            ]
        }
    }

    /// Bucket queued jobs into per-pool demand counts.
    public func demandByPool(for jobs: [ForgeJob], forgeID: ForgeID) -> [RuntimeID: Int] {
        var counts: [RuntimeID: Int] = [:]
        let defaultPool = pools[defaultRuntime] ?? RuntimePool(runtime: .tart, labels: [])
        for job in jobs {
            let decision = RuntimeRouter.assign(job: job, config: self, defaultPool: defaultPool, pools: pools)
            counts[decision.pool.runtime, default: 0] += 1
        }
        return counts
    }

    /// True when the pool exists (its runtime is configured).
    public func poolExists(_ runtime: RuntimeID) -> Bool {
        pools[runtime] != nil
    }
}

// MARK: - Weighted capacity partition

/// Splits the host's usable budget between runtimes by configured weights.
/// The default runtime receives the remainder when weights sum below 1.
public enum RuntimeCapacity {
    public struct Partition: Sendable, Equatable {
        /// Per-runtime caps (in VMs/containers of that runtime's shape).
        public let caps: [RuntimeID: Int]
        /// Human summary for status/doctor lines.
        public let summary: String
    }

    public static func partition(
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
