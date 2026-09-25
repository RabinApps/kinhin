import Foundation

/// User-facing configuration, loaded from `~/Library/Application Support/Kinhin/config.yaml`.
public struct KinhinConfig: Sendable, Equatable {
    public struct VM: Sendable, Equatable {
        /// Number of virtual CPUs assigned to each runner VM.
        public var cpuCount: Int
        /// Memory (GB) assigned to each runner VM.
        public var memoryGB: Int
        /// Delete each VM as soon as its job finishes (ephemeral mode).
        public var ephemeral: Bool

        enum CodingKeys: String, CodingKey {
            case cpuCount = "cpu"
            case memoryGB = "memory_gb"
            case ephemeral
        }

        public static let `default` = VM(cpuCount: 4, memoryGB: 8, ephemeral: true)
    }

    /// GitHub repository to serve, e.g. "acme/widgets". The starter
    /// template's placeholder means "no GitHub": a config with a `gitea:`
    /// section and this placeholder serves Gitea only (see `githubEnabled`).
    public var repo: String

    /// True when GitHub is a real forge for this config (a real repo/org,
    /// not empty and not the starter placeholder).
    public var githubEnabled: Bool { !repo.isEmpty && repo != ConfigLoader.templateRepo }
    /// Labels a job must request (subset of these) to be picked up by this fleet.
    public var labels: [String]
    /// Never run fewer than this many idle runners.
    public var minRunners: Int
    /// Hard upper bound on simultaneous VMs.
    public var maxRunners: Int
    /// Runner processes per VM (many-to-one: one VM serves this many jobs
    /// concurrently). 1 = classic one-runner-per-VM.
    public var runnersPerVM: Int
    /// Poll interval for GitHub in seconds.
    public var pollInterval: Int
    /// Registration-token cache TTL in seconds (GitHub tokens expire after 1 hour).
    var tokenTTL: Int
    /// Per-VM resource settings.
    public var vm: VM
    /// Tart image to clone for each runner, e.g. "tahoe-base" (prepared via `kinhin image prepare`).
    public var image: String
    /// How long a freshly booted VM may take to join as a registered runner (seconds).
    var vmBootTimeout: Int
    /// Optional extra disk (GB) attached to each VM.
    public var diskGB: Int?
    /// Optional tart binary path override.
    public var tartPath: String?
    /// Reserve headroom on the host so your Mac stays responsive.
    public var reserve: Reserve
    /// Gitea forge settings (absent → Gitea not served by this fleet).
    public var gitea: GiteaForgeConfig?
    /// Apple-container runtime settings (nil → feature off; VMs always used).
    public var container: ContainerConfig?
    /// Per-repo/per-workflow runtime routing (nil → the legacy single-pool
    /// behavior: every VM uses the engine's one runtime and fleet labels).
    public var runtimes: RuntimeConfig?
    /// Host path to a script baked into the base image by
    /// `kinhin image prepare` (after the runner agents install) — the place
    /// for toolchains every runner VM should boot with (Go, Rust, a JDK…).
    public var provisionScript: String? = nil
    /// Managed toolchains: declarative runtimes installed and pinned into
    /// the base image by `kinhin image prepare` (no hand-written script
    /// required), with a host-side download cache shared across prepares —
    /// and, opt-in, across runner VMs. nil = feature off, behavior unchanged.
    public var toolchains: ToolchainsConfig? = nil
    /// Docker runtime (Linux containers inside the provider's shared VM —
    /// Docker Desktop/OrbStack/colima). kinhin delegates the VM and manages
    /// nothing; it runs one container per job slot. nil = feature off.
    public var docker: DockerForgeConfig? = nil

    /// Declarative toolchain installs baked by `image prepare`. Every entry
    /// installs exactly its own pieces — nothing is added implicitly. The
    /// catalog (see `ToolchainCatalog`) is advisory: unknown `specs` pass
    /// through to mise and unknown `brew` formulas pass through to brew.
    public struct ToolchainsConfig: Sendable, Equatable {
        /// mise specs, e.g. "go@1.23.4", "node@22", "java@temurin-17".
        /// Installed with `mise use --global` so every runner shell sees them.
        public var specs: [String]? = nil
        /// Homebrew formulas/casks, e.g. "wget", "yamllint".
        public var brew: [String]? = nil
        /// Curated multi-tool recipes from the catalog, e.g. "flutter",
        /// "flutter@3.24.0" (SDK version), "expo", "react-native", "vercel",
        /// "cloudflare".
        public var stacks: [String]? = nil
        /// Opt-in: mount the host toolchain cache into every runner VM so
        /// per-job installs (`npm ci`, `mise install`, `fvm install`,
        /// `dotnet restore`) hit warm cache. Best-effort: concurrent VM
        /// writers are tolerated by these tools (worst case a re-download).
        public var shareCache: Bool? = nil
        /// Host-side cache auto-expiry policy. Baked images are never
        /// touched — only the regenerable download cache on the host.
        public var cache: CachePolicy? = nil

        /// Memberwise init is internal; this public init supports CLI
        /// flag-only construction (e.g. `image prepare --toolchain go@1.23`).
        public init(
            specs: [String]? = nil, brew: [String]? = nil, stacks: [String]? = nil, shareCache: Bool? = nil,
            cache: CachePolicy? = nil
        ) {
            self.specs = specs
            self.brew = brew
            self.stacks = stacks
            self.shareCache = shareCache
            self.cache = cache
        }

        public struct CachePolicy: Sendable, Equatable {
            /// Daily prune while the fleet engine runs, and a sweep after
            /// each successful image prepare.
            public var autoPrune: Bool? = nil
            /// Entries unused this many days are deleted (0 = no age limit).
            public var maxAgeDays: Int? = nil
            /// LRU eviction beyond this total size in GB (0 = no size limit).
            public var maxGB: Int? = nil

            enum CodingKeys: String, CodingKey {
                case autoPrune = "auto_prune"
                case maxAgeDays = "max_age_days"
                case maxGB = "max_gb"
            }
        }

        enum CodingKeys: String, CodingKey {
            case specs, brew, stacks
            case shareCache = "share_cache"
            case cache
        }
    }

    public struct ContainerConfig: Sendable, Equatable {
        /// Linux OCI image to run each runner container from (must be
        /// prepared with the runner agents via `kinhin image prepare`).
        public var image: String
        /// vCPUs per runner container.
        public var cpus: Int
        /// RAM (GB) per runner container.
        public var memoryGB: Int
        /// Image `kinhin image prepare --container` bakes on top of; nil uses
        /// `LinuxBaseImage.defaultReference`. Debian/Ubuntu-based images only.
        public var baseImage: String?

        public init(
            image: String, cpus: Int = 4, memoryGB: Int = 8, labels: [String]? = nil, baseImage: String? = nil
        ) {
            self.image = image
            self.cpus = cpus
            self.memoryGB = memoryGB
            self.labels = labels
            self.baseImage = baseImage
        }

        /// Extra labels the Apple-container pool's runners register with, so
        /// workflows can opt in per job (`runs-on: [kinhin-container]`).
        /// Always merged with "kinhin-container" at pool construction.
        public var labels: [String]?

        enum CodingKeys: String, CodingKey {
            case image, cpus, labels
            case memoryGB = "memory_gb"
            case baseImage = "base_image"
        }
    }

    /// Docker runtime settings. `max_slots` bounds the container slots this
    /// fleet may run (capacity is also bounded by the host budget partition
    /// like every other runtime).
    public struct DockerForgeConfig: Sendable, Equatable {
        /// Linux OCI image baked with the runner agents (kinhin image
        /// prepare --docker).
        public var image: String
        /// vCPUs per runner container.
        public var cpus: Int
        /// RAM (GB) per runner container.
        public var memoryGB: Int
        /// Hard upper bound on concurrent container slots.
        public var maxSlots: Int
        /// Image `kinhin image prepare --docker` bakes on top of; nil uses
        /// `LinuxBaseImage.defaultReference`. Debian/Ubuntu-based images only.
        public var baseImage: String?

        public init(image: String, cpus: Int = 2, memoryGB: Int = 4, maxSlots: Int = 8, baseImage: String? = nil) {
            self.image = image
            self.cpus = cpus
            self.memoryGB = memoryGB
            self.maxSlots = maxSlots
            self.baseImage = baseImage
        }

        enum CodingKeys: String, CodingKey {
            case image, cpus
            case memoryGB = "memory_gb"
            case maxSlots = "max_slots"
            case baseImage = "base_image"
        }
    }

    /// Routing configuration: which execution runtime serves which repo or
    /// workflow. One fleet can mix macOS jobs on Tart VMs and Linux jobs in
    /// Apple containers. Each runtime gets its own label pool so workflows
    /// opt in per job via `runs-on:`.
    public struct RuntimeConfig: Sendable, Equatable {
        /// Runtime for repos with no matching route.
        public var defaultRuntime: String
        /// Deterministic split of the host budget between runtimes
        /// (fractions of the usable CPU+RAM budget; the remainder, if any,
        /// goes to the default runtime).
        public var budget: [String: Double]
        /// Repo or `RabinApps/repo@workflow` → runtime. Repo routes take
        /// precedence over workflow routes; first matching route wins.
        public var routes: [Route]

        public struct Route: Sendable, Equatable {
            /// "RabinApps/name" or "RabinApps/name@Workflow Name".
            public var pattern: String
            public var runtime: String

            public init(pattern: String, runtime: String) {
                self.pattern = pattern
                self.runtime = runtime
            }

            enum CodingKeys: String, CodingKey {
                case pattern, runtime
            }
        }

        public init(
            defaultRuntime: String = RuntimeID.tart.rawValue, budget: [String: Double] = [:], routes: [Route] = []
        ) {
            self.defaultRuntime = defaultRuntime
            self.budget = budget
            self.routes = routes
        }

        enum CodingKeys: String, CodingKey {
            case defaultRuntime = "default"
            case budget, routes
        }
    }

    public struct GiteaForgeConfig: Sendable, Equatable {
        /// Instance base URL, e.g. "https://gitea.example.com".
        public var instance: String
        /// Scope: "RabinApps/name" or org name (mirrors the GitHub scope model).
        public var scope: String
        /// Labels jobs must request on Gitea (host-mode, e.g. ["macos:host"]).
        public var labels: [String]?

        public init(instance: String, scope: String, labels: [String]? = nil) {
            self.instance = instance
            self.scope = scope
            self.labels = labels
        }

        enum CodingKeys: String, CodingKey {
            case instance, scope, labels
        }
    }

    public struct Reserve: Sendable, Equatable {
        /// Host cores kept free from VM budgets.
        public var cpu: Int
        /// Host memory (GB) kept free from VM budgets.
        public var memoryGB: Int

        enum CodingKeys: String, CodingKey {
            case cpu
            case memoryGB = "memory_gb"
        }

        public static let `default` = Reserve(cpu: 2, memoryGB: 4)
    }

    enum CodingKeys: String, CodingKey {
        case repo, labels, image
        case minRunners = "min_runners"
        case maxRunners = "max_runners"
        case runnersPerVM = "runners_per_vm"
        case pollInterval = "poll_interval"
        case tokenTTL = "token_ttl"
        case vm
        case diskGB = "disk_gb"
        case tartPath = "tart_path"
        case reserve
        case gitea
        case container
        case docker
        case runtimes
        case provisionScript = "provision_script"
        case toolchains
    }

    public static let `default` = KinhinConfig(
        repo: "",
        labels: ["self-hosted", "macos", "arm64"],
        minRunners: 0,
        maxRunners: 2,
        runnersPerVM: 1,
        pollInterval: 20,
        tokenTTL: 50 * 60,
        vm: .default,
        image: "tahoe-base",
        vmBootTimeout: 300,
        diskGB: nil,
        tartPath: nil,
        reserve: .default,
        container: nil,
        runtimes: nil,
        provisionScript: nil,
        toolchains: nil,
        docker: nil
    )
}
