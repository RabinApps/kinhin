import Foundation

extension KinhinConfig {
    /// Routing configuration: which execution runtime serves which repo or
    /// workflow. One fleet can mix macOS jobs on Tart VMs and Linux jobs in
    /// Apple containers, Docker containers, or full Tart Linux VMs. Each runtime
    /// gets its own label pool so workflows opt in per job via `runs-on:`.
    /// A Tart fleet can serve macOS and Linux VMs together when named images have
    /// distinct labels — a Linux-named image's runners strip the fleet's `macos`
    /// label automatically.
    public struct RuntimeConfig: Sendable, Equatable {
        /// Runtime for repos with no matching route.
        public var defaultRuntime: RuntimeID
        /// Deterministic split of the host budget between runtimes
        /// (fractions of the usable CPU+RAM budget; the remainder, if any,
        /// goes to the default runtime).
        public var budget: [String: Double]
        /// Repo or `owner/repo@workflow` → runtime. Repo routes take
        /// precedence over workflow routes; first matching route wins.
        public var routes: [Route]
        /// `runtimes.tart.enabled` (default true). false takes the Tart VM pool out of routing and scheduling;
        /// running VMs drain.
        public var tartEnabled: Bool

        public struct Route: Sendable, Equatable {
            /// "owner/name" or "owner/name@Workflow Name".
            public var pattern: String
            public var runtime: RuntimeID
            /// Host-mode consent: routes with `runtime: host` MUST carry
            /// `consent: true` (validated), acknowledging that jobs from this
            /// repo/workflow run directly on the Mac, unisolated. Meaningless
            /// (and rejected) for other runtimes.
            public var consent: Bool?

            public init(pattern: String, runtime: RuntimeID, consent: Bool? = nil) {
                self.pattern = pattern
                self.runtime = runtime
                self.consent = consent
            }

            enum CodingKeys: String, CodingKey {
                case pattern, runtime, consent
            }
        }

        public init(
            defaultRuntime: RuntimeID = .tart, budget: [String: Double] = [:], routes: [Route] = [],
            tartEnabled: Bool = true
        ) {
            self.tartEnabled = tartEnabled
            self.defaultRuntime = defaultRuntime
            self.budget = budget
            self.routes = routes
        }

        enum CodingKeys: String, CodingKey {
            case defaultRuntime = "default"
            case budget, routes
            case tartEnabled = "tart"
        }
    }
}

extension KinhinConfig {
    /// The Apple-container section when it takes jobs: configured, switched on, and with at least one enabled pool.
    /// nil when it is absent or disabled. Capacity, routing and health read this; the engine still builds a disabled
    /// section's runtime from `container`, so its running instances drain.
    public var activeContainer: ContainerConfig? {
        guard let container, container.enabled, !container.enabledPools.isEmpty else { return nil }
        return container
    }

    /// The Docker section when it takes jobs (see `activeContainer`).
    public var activeDocker: DockerForgeConfig? {
        guard let docker, docker.enabled else { return nil }
        return docker
    }

    /// Whether the Tart VM pool takes jobs (`runtimes.tart.enabled`, default true).
    public var tartEnabled: Bool { runtimes?.tartEnabled ?? true }
}
