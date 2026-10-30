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

    /// Labels a job must request (subset of these) to be picked up by this fleet.
    public var labels: [String]
    /// Never run fewer than this many idle runners.
    public var minRunners: Int
    /// Hard upper bound on simultaneous VMs.
    public var maxRunners: Int
    /// VMs kept booted and SSH-ready but not yet registered, so a job skips clone and boot.
    /// They occupy slots under `maxRunners`. 0 = off.
    public var warmPool: Int = 0
    /// A warm VM older than this many minutes is recycled so it does not drift stale.
    public var warmMaxAgeMinutes: Int = 60
    /// Runner processes per VM (many-to-one: one VM serves this many jobs
    /// concurrently). 1 = classic one-runner-per-VM.
    public var runnersPerVM: Int
    /// Poll interval for GitHub in seconds.
    public var pollInterval: Int
    /// Autoscale unpauses a paused fleet once its queue is empty. Lets a
    /// deliberate pause (e.g. a pause-first VM delete from Shortcuts)
    /// hold down while work remains, then release the fleet on its own.
    public var autoResume: Bool
    /// Registration-token cache TTL in seconds (GitHub tokens expire after 1 hour).
    var tokenTTL: Int
    /// Per-VM resource settings.
    public var vm: VM
    /// Tart image to clone for each runner, e.g. "tahoe-base" (prepared via `kinhin image prepare`).
    public var image: String
    /// Runner labels the default `image:` advertises on top of the fleet `labels:` — the named-image
    /// `labels:` rule, but for the top-level image (which has no `images:` entry of its own). Typical
    /// use: a Linux default base keeps its macOS fleet labels stripped and answers a `linux` label.
    /// Follows the images-entry validation (at least one label outside the fleet labels; no label set
    /// shared with a named entry) and the macOS-strip rule. nil = no extra labels.
    public var imageLabels: [String]? = nil
    /// What `image prepare` starts from: a curated tart reference (see
    /// `TartBaseImage.curated`), any other registry reference, or a local VM
    /// name (e.g. one created with `image prepare --linux`). nil = the
    /// default macOS base.
    public var baseImage: String? = nil
    /// Additional named images beside `image:` (for example one baked on a
    /// Cirrus `-xcode` base, or a Linux base for Linux jobs). Each is prepared
    /// separately with `kinhin image prepare --image <name>`. Empty = just
    /// `image:`. A fleet can run macOS and Linux Tart VMs together when images
    /// carry distinct labels — Linux-named images strip the fleet's `macos` label
    /// so they do not attract macOS jobs.
    public var images: [ImageConfig] = []
    /// How long a freshly booted VM may take to join as a registered runner (seconds).
    var vmBootTimeout: Int
    /// Extra scratch disk (GB) attached to each VM. 0 disables the extra
    /// disk; nil means "not configured" (the scaler then assumes a default
    /// per-VM disk footprint — see `effectiveDiskPerVMGB`).
    public var diskGB: Int?
    /// Optional tart binary path override.
    public var tartPath: String?
    /// Boot runner VMs with `tart run --net-softnet`: each VM can reach the
    /// internet but not the other runner VMs or the local network. Needs the
    /// `softnet` binary (see docs/runtimes.md). Nil/false = Tart's default
    /// shared network, where VMs can reach each other.
    public var tartSoftnet: Bool?
    /// Reserve headroom on the host so your Mac stays responsive.
    public var reserve: Reserve
    /// Apple-container runtime settings (nil → feature off; VMs always used).
    public var container: ContainerConfig?
    /// Per-repo/per-workflow runtime routing (nil → the legacy single-pool
    /// behavior: every VM uses the engine's one runtime and fleet labels).
    public var runtimes: RuntimeConfig?
    /// Host path to a script baked into the base image by
    /// `kinhin image prepare` (after the runner agents install) — the place
    /// for toolchains every runner VM should boot with (Go, Rust, a JDK…).
    public var provisionScript: String? = nil
    /// Host download-cache auto-expiry policy (`toolchain_cache:`). Baked
    /// images are never touched, only the regenerable cache on the host.
    public var toolchainCache: ToolchainCacheConfig? = nil
    /// Most derived per-project images kept (`max_project_images:`, nil = 8);
    /// the least recently used are deleted beyond it.
    public var maxProjectImages: Int? = nil
    /// Per-project toolchain scopes (`projects:`): which repos may declare
    /// their own toolchains in a `.kinhin.yml`, and per-repo toolchains.
    /// Every project is independent; repos matching no entry get the plain
    /// base image with no toolchains baked.
    public var projects: [ProjectConfig] = []
    /// Docker runtime (Linux containers inside the provider's shared VM —
    /// Docker Desktop/OrbStack/colima). kinhin delegates the VM and manages
    /// nothing; it runs one container per job slot. nil = feature off.
    public var docker: DockerForgeConfig? = nil
    /// Additional forge accounts beyond the legacy `repo:` / `gitea:` ones,
    /// each with its own Keychain token. See `allAccounts` for the full set.
    public var accounts: [AccountConfig] = []
    /// The healing agent's policy (`healing:`).
    public var healing: HealingConfig = .default
    /// Observability (`telemetry:`): off unless `enabled: true`.
    public var telemetry: TelemetryConfig = .default

    /// True when any project mounts the host toolchain cache into its runners.
    public var sharesToolchainCache: Bool { projects.contains { $0.shareCache == true } }

    /// The engine-facing image table: the named `images:` entries, plus — when the default
    /// `image:` needs a voice of its own — a synthesized entry named after `image:`.
    /// That is the case when `image_labels` is set (labels on the default image), or when the
    /// default base is a Linux image (its runners must have the fleet's `macos` label stripped).
    /// The synthesized entry carries `warm_pool` 0: the default image's warm pool is the
    /// top-level `warm_pool:`, which stays keyed separately (see `ScalePlan.warmPool`).
    public func effectiveImages() -> [ImageConfig] {
        let linuxDefault = baseImage.map { TartBaseImage.isLinux($0) } ?? false
        guard imageLabels != nil || linuxDefault else { return images }
        let synthesized = ImageConfig(name: image, baseImage: baseImage, labels: imageLabels, warmPool: 0)
        return images + [synthesized]
    }

    // MARK: - Forge views (derived from `accounts`)

    /// The primary GitHub account: the entry named "github" when present,
    /// else the first `forge: github` entry. The engine attaches it as the
    /// "github" platform at construction, and `replaceCredentials` swaps its
    /// token live; further GitHub accounts attach under their own names.
    public var primaryGitHub: AccountConfig? {
        accounts.first { $0.name == ForgeID.github.rawValue && $0.forge == .github }
            ?? accounts.first { $0.forge == .github }
    }

    /// The primary GitHub account's scope ("" when GitHub isn't configured).
    public var repo: String { primaryGitHub?.scope ?? "" }

    /// True when a GitHub account is configured.
    public var githubEnabled: Bool { primaryGitHub != nil }

    /// The primary Gitea account as a forge config (the entry named "gitea"
    /// when present, else the first `forge: gitea` entry; nil when none).
    public var gitea: GiteaForgeConfig? {
        forgeView(.gitea)
    }

    /// The primary Forgejo account as a forge config (same naming rule as
    /// `gitea`; nil when none).
    public var forgejo: ForgejoForgeConfig? {
        forgeView(.forgejo)
    }

    private func forgeView(_ forge: ForgeID) -> GiteaForgeConfig? {
        let entry =
            accounts.first { $0.name == forge.rawValue && $0.forge == forge }
            ?? accounts.first { $0.forge == forge }
        return entry.map { GiteaForgeConfig(instance: $0.instance ?? "", scope: $0.scope, labels: $0.labels) }
    }

    /// True when any route targets host execution (the HostRuntime joins the
    /// fleet only then — its agent check and pool never appear otherwise).
    public var hostRoutesConfigured: Bool {
        runtimes?.routes.contains { $0.runtime == .host } ?? false
    }

    /// Declarative toolchain installs for one project. Every entry installs
    /// exactly its own pieces, nothing is added implicitly. The catalog (see
    /// `ToolchainCatalog`) is advisory: unknown `specs` pass through to mise
    /// and unknown `brew` formulas pass through to brew (config entries
    /// only; a repo's `.kinhin.yml` is catalog-only).
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

        public init(specs: [String]? = nil, brew: [String]? = nil, stacks: [String]? = nil) {
            self.specs = specs
            self.brew = brew
            self.stacks = stacks
        }

        enum CodingKeys: String, CodingKey {
            case specs, brew, stacks
        }
    }

    /// Host toolchain-cache auto-expiry policy.
    public struct ToolchainCacheConfig: Sendable, Equatable {
        /// Daily prune while the fleet engine runs, and a sweep after
        /// each successful image prepare.
        public var autoPrune: Bool? = nil
        /// Entries unused this many days are deleted (0 = no age limit).
        public var maxAgeDays: Int? = nil
        /// LRU eviction beyond this total size in GB (0 = no size limit).
        public var maxGB: Int? = nil

        public init(autoPrune: Bool? = nil, maxAgeDays: Int? = nil, maxGB: Int? = nil) {
            self.autoPrune = autoPrune
            self.maxAgeDays = maxAgeDays
            self.maxGB = maxGB
        }

        enum CodingKeys: String, CodingKey {
            case autoPrune = "auto_prune"
            case maxAgeDays = "max_age_days"
            case maxGB = "max_gb"
        }
    }

    /// One `images:` entry: an extra prepared tart image with its own base.
    public struct ImageConfig: Sendable, Equatable {
        /// The prepared tart VM name `image prepare --image` creates.
        public var name: String
        /// What this image's prepare starts from (curated reference, registry
        /// reference, or local VM name); nil = the default macOS base.
        public var baseImage: String?
        /// Runner labels this image advertises on top of the fleet `labels:`.
        /// A job that requests these labels runs on this image (see `ImageRouting`).
        public var labels: [String]?
        /// Booted, unregistered clones of this image kept ready for its jobs; 0 = off.
        public var warmPool: Int

        public init(name: String, baseImage: String? = nil, labels: [String]? = nil, warmPool: Int = 0) {
            self.name = name
            self.baseImage = baseImage
            self.labels = labels
            self.warmPool = warmPool
        }

        enum CodingKeys: String, CodingKey {
            case name, labels
            case baseImage = "base_image"
            case warmPool = "warm_pool"
        }
    }

    public struct GiteaForgeConfig: Sendable, Equatable {
        /// Instance base URL, e.g. "https://gitea.example.com".
        public var instance: String
        /// Scope: "owner/name" or org name (mirrors the GitHub scope model).
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

    /// Forgejo forge settings (Gitea's upstream — wire-compatible, so the
    /// same client and runner binary serve it; nil → Forgejo not served).
    public typealias ForgejoForgeConfig = GiteaForgeConfig

    public struct Reserve: Sendable, Equatable {
        /// Host cores kept free from VM budgets.
        public var cpu: Int
        /// Host memory (GB) kept free from VM budgets.
        public var memoryGB: Int
        /// Host disk (GB) kept free from VM scratch. The scaler holds new
        /// spawns when free disk would dip below this plus one VM's disk
        /// footprint.
        public var diskGB: Int

        enum CodingKeys: String, CodingKey {
            case cpu
            case memoryGB = "memory_gb"
            case diskGB = "disk_gb"
        }

        public static let `default` = Reserve(cpu: 2, memoryGB: 4, diskGB: 10)
    }

    enum CodingKeys: String, CodingKey {
        case labels, image, images, baseImage = "base_image"
        case imageLabels = "image_labels"
        case minRunners = "min_runners"
        case maxRunners = "max_runners"
        case warmPool = "warm_pool"
        case warmMaxAgeMinutes = "warm_max_age_minutes"
        case runnersPerVM = "runners_per_vm"
        case pollInterval = "poll_interval"
        case autoResume = "auto_resume"
        case tokenTTL = "token_ttl"
        case vm
        case diskGB = "disk_gb"
        case tartPath = "tart_path"
        case tartSoftnet = "tart_softnet"
        case reserve
        case container
        case docker
        case runtimes
        case provisionScript = "provision_script"
        case toolchainCache = "toolchain_cache"
        case maxProjectImages = "max_project_images"
        case projects
        case accounts
        case healing
        case telemetry
    }

    public static let `default` = KinhinConfig(
        labels: ["self-hosted", "macos", "arm64"],
        minRunners: 0,
        maxRunners: 2,
        runnersPerVM: 1,
        pollInterval: 20,
        autoResume: false,
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
        docker: nil
    )
}
