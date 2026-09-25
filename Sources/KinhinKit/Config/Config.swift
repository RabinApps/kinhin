import Foundation
import Yams

/// User-facing configuration, loaded from `~/Library/Application Support/Kinhin/config.yaml`.
public struct kinhinConfig: Sendable, Equatable {
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
    public var tokenTTL: Int
    /// Per-VM resource settings.
    public var vm: VM
    /// Tart image to clone for each runner, e.g. "tahoe-base" (prepared via `kinhin image prepare`).
    public var image: String
    /// How long a freshly booted VM may take to join as a registered runner (seconds).
    public var vmBootTimeout: Int
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

        public init(image: String, cpus: Int = 4, memoryGB: Int = 8, labels: [String]? = nil) {
            self.image = image
            self.cpus = cpus
            self.memoryGB = memoryGB
            self.labels = labels
        }

        /// Extra labels the Apple-container pool's runners register with, so
        /// workflows can opt in per job (`runs-on: [kinhin-container]`).
        /// Always merged with "kinhin-container" at pool construction.
        public var labels: [String]?

        enum CodingKeys: String, CodingKey {
            case image, cpus, labels
            case memoryGB = "memory_gb"
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

        public init(image: String, cpus: Int = 2, memoryGB: Int = 4, maxSlots: Int = 8) {
            self.image = image
            self.cpus = cpus
            self.memoryGB = memoryGB
            self.maxSlots = maxSlots
        }

        enum CodingKeys: String, CodingKey {
            case image, cpus
            case memoryGB = "memory_gb"
            case maxSlots = "max_slots"
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

    public static let `default` = kinhinConfig(
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

public enum ConfigError: LocalizedError, Equatable {
    case missing(String)
    case invalid(String)
    case notFound(String)
    case unreadable(String)

    public var errorDescription: String? {
        switch self {
        case .missing(let key): return "config: missing required key '\(key)'"
        case .invalid(let why): return "config: \(why)"
        case .notFound(let path): return "config not found at \(path) — run `kinhin config init` to create one"
        case .unreadable(let path): return "config could not be read at \(path)"
        }
    }
}

/// Loads and validates `kinhinConfig`.
public struct ConfigLoader {
    public init() {}

    /// The repo value written by the starter template. A config containing it
    /// is a *template*, not a working config — the engine must refuse to run
    /// against it and the checklist must ask for a real repo instead of
    /// showing a green checkmark over a placeholder.
    public static let templateRepo = "your-org/your-repo"

    /// True when the parsed config still carries the template's placeholder repo.
    public static func isTemplate(_ cfg: kinhinConfig) -> Bool {
        cfg.repo == templateRepo
    }

    /// The GitHub token the engine is built with. With GitHub configured it is
    /// the Keychain PAT; if that is missing but a Gitea forge is configured
    /// with its own token, an empty placeholder lets the fleet run on Gitea
    /// alone (GitHub then reports its problem instead of blocking startup).
    /// Gitea-only configs also get the placeholder. Nil when no configured
    /// forge has a usable token.
    public static func engineToken(
        for cfg: kinhinConfig, load: (ForgeID) -> String? = { KeychainTokenStore.load(forge: $0) }
    ) -> String? {
        let giteaReady = cfg.gitea != nil && load(.gitea) != nil
        if cfg.githubEnabled {
            if let token = load(.github) { return token }
            return giteaReady ? "" : nil
        }
        return giteaReady ? "" : nil
    }

    /// True when at least one forge is configured for real work.
    public static func hasAnyForge(_ cfg: kinhinConfig) -> Bool {
        cfg.githubEnabled || cfg.gitea != nil
    }

    /// Creates the starter config on first run. Never overwrites: an existing
    /// file (template or hand-edited) is left alone. Returns true when a file
    /// was written.
    @discardableResult
    public static func createIfMissing(at url: URL = Paths.config) -> Bool {
        let fm = FileManager.default
        guard !fm.fileExists(atPath: url.path) else { return false }
        Paths.ensureSupportDirectories()
        do {
            try template().write(toFile: url.path, atomically: true, encoding: .utf8)
            return true
        } catch {
            // Auto-creation is a convenience; a failure here (permissions,
            // full disk) must never take the app down. The checklist will
            // still show "not created yet" with a repair action.
            return false
        }
    }

    public static func load(from url: URL = Paths.config) throws -> kinhinConfig {
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw ConfigError.notFound(url.path)
        }
        guard let yaml = try? String(contentsOf: url, encoding: .utf8) else {
            throw ConfigError.unreadable(url.path)
        }
        return try Self.parse(yaml)
    }

    public static func parse(_ yaml: String) throws -> kinhinConfig {
        let partial = try YAMLDecoder().decode(PartialConfig.self, from: yaml)

        guard let repo = partial.repo, !repo.isEmpty else {
            throw ConfigError.missing("repo")
        }
        // Scope: "RabinApps/name" (one repository) or a single segment (an org —
        // org-level runners serve every repo in the organization).
        let scopeSegments = repo.split(separator: "/")
        guard (1...2).contains(scopeSegments.count),
            scopeSegments.allSatisfy({ !$0.isEmpty })
        else {
            throw ConfigError.invalid("scope must be 'RabinApps/name' or an org name, got '\(repo)'")
        }
        guard let labels = partial.labels, !labels.isEmpty else {
            throw ConfigError.missing("labels")
        }
        let minRunners = partial.min_runners ?? 0
        let maxRunners = partial.max_runners ?? 1
        if minRunners < 0 { throw ConfigError.invalid("min_runners must be >= 0") }
        if maxRunners < 1 { throw ConfigError.invalid("max_runners must be >= 1") }
        if maxRunners < minRunners {
            throw ConfigError.invalid("max_runners (\(maxRunners)) must be >= min_runners (\(minRunners))")
        }
        let runnersPerVM = partial.runners_per_vm ?? 1
        if runnersPerVM < 1 { throw ConfigError.invalid("runners_per_vm must be >= 1") }
        if runnersPerVM > 8 {
            throw ConfigError.invalid("runners_per_vm must be <= 8 (each runner shares the VM's CPU and RAM)")
        }
        let poll = partial.poll_interval ?? 20
        if poll < 5 {
            throw ConfigError.invalid("poll_interval must be >= 5 seconds to stay within GitHub rate limits")
        }

        var cfg = kinhinConfig.default
        cfg.repo = repo
        cfg.labels = labels
        cfg.minRunners = minRunners
        cfg.maxRunners = maxRunners
        cfg.runnersPerVM = runnersPerVM
        cfg.pollInterval = poll
        if let ttl = partial.token_ttl { cfg.tokenTTL = ttl }
        if let vm = partial.vm {
            if let cpu = vm.cpu, cpu < 1 { throw ConfigError.invalid("vm.cpu must be >= 1") }
            if let mem = vm.memory_gb, mem < 2 { throw ConfigError.invalid("vm.memory_gb must be >= 2") }
            if let e = vm.ephemeral { cfg.vm.ephemeral = e }
            if let cpu = vm.cpu { cfg.vm.cpuCount = cpu }
            if let mem = vm.memory_gb { cfg.vm.memoryGB = mem }
        }
        if let image = partial.image {
            guard !image.isEmpty else { throw ConfigError.invalid("image must not be empty") }
            cfg.image = image
        }
        if let boot = partial.vm_boot_timeout { cfg.vmBootTimeout = boot }
        if let disk = partial.disk_gb {
            guard disk >= 0 else { throw ConfigError.invalid("disk_gb must be >= 0") }
            cfg.diskGB = disk
        }
        if let tartPath = partial.tart_path { cfg.tartPath = tartPath }
        if let provision = partial.provision_script {
            guard !provision.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw ConfigError.invalid(
                    "provision_script must not be empty (remove the key or point it at a script file)")
            }
            cfg.provisionScript = provision
        }
        if let toolchains = partial.toolchains {
            cfg.toolchains = try Self.parseToolchains(toolchains)
        }
        if let gitea = partial.gitea {
            guard let instance = gitea.instance, !instance.isEmpty else {
                throw ConfigError.invalid("gitea.instance is required (e.g. https://gitea.example.com)")
            }
            guard (try? GiteaCredentials.validate(instance: instance)) != nil else {
                throw ConfigError.invalid(
                    "gitea.instance must be a base URL like https://gitea.example.com (no path, no /api suffix)")
            }
            guard let scope = gitea.scope, !scope.isEmpty else {
                throw ConfigError.invalid("gitea.scope is required ('RabinApps/name' or an org name)")
            }
            let scopeSegments = scope.split(separator: "/")
            guard (1...2).contains(scopeSegments.count),
                scopeSegments.allSatisfy({ !$0.isEmpty })
            else {
                throw ConfigError.invalid("gitea.scope must be 'RabinApps/name' or an org name, got '\(scope)'")
            }
            if let giteaLabels = gitea.labels, giteaLabels.isEmpty {
                throw ConfigError.invalid("gitea.labels must be non-empty when present")
            }
            cfg.gitea = kinhinConfig.GiteaForgeConfig(instance: instance, scope: scope, labels: gitea.labels)
        }
        if let container = partial.container {
            guard let containerImage = container.image, !containerImage.isEmpty else {
                throw ConfigError.invalid(
                    "container.image must not be empty (a Linux OCI image baked with runner agents)")
            }
            if let cpus = container.cpus, cpus < 1 {
                throw ConfigError.invalid("container.cpus must be >= 1")
            }
            if let mem = container.memory_gb, mem < 2 {
                throw ConfigError.invalid("container.memory_gb must be >= 2")
            }
            cfg.container = kinhinConfig.ContainerConfig(
                image: containerImage,
                cpus: container.cpus ?? 4,
                memoryGB: container.memory_gb ?? 8,
                labels: container.labels
            )
        }
        if let docker = partial.docker {
            guard let dockerImage = docker.image, !dockerImage.isEmpty else {
                throw ConfigError.invalid("docker.image must not be empty (a Linux OCI image baked with runner agents)")
            }
            if let cpus = docker.cpus, cpus < 1 {
                throw ConfigError.invalid("docker.cpus must be >= 1")
            }
            if let mem = docker.memory_gb, mem < 1 {
                throw ConfigError.invalid("docker.memory_gb must be >= 1")
            }
            if let slots = docker.max_slots, slots < 1 {
                throw ConfigError.invalid("docker.max_slots must be >= 1")
            }
            cfg.docker = kinhinConfig.DockerForgeConfig(
                image: dockerImage,
                cpus: docker.cpus ?? 2,
                memoryGB: docker.memory_gb ?? 4,
                maxSlots: docker.max_slots ?? 8
            )
        }
        if let runtimes = partial.runtimes {
            var budget: [String: Double] = [:]
            if let entries = runtimes.budget {
                for (runtime, weight) in entries {
                    guard weight > 0, weight <= 1 else {
                        throw ConfigError.invalid(
                            "runtimes.budget weights must be in (0, 1], got \(runtime): \(weight)")
                    }
                    budget[runtime] = weight
                }
            }
            var routes: [kinhinConfig.RuntimeConfig.Route] = []
            for route in runtimes.routes ?? [] {
                guard let pattern = route.pattern, !pattern.isEmpty else {
                    throw ConfigError.invalid("runtimes.routes entries need a non-empty pattern")
                }
                guard let runtime = route.runtime, !runtime.isEmpty else {
                    throw ConfigError.invalid("runtimes.routes entry '\(pattern)' needs a runtime")
                }
                let segments = pattern.split(separator: "/")
                let isWorkflow = pattern.contains("@")
                if isWorkflow {
                    let repoPart = String(pattern.split(separator: "@").first ?? "")
                    guard repoPart.split(separator: "/").count == 2, !repoPart.hasSuffix("@") else {
                        throw ConfigError.invalid(
                            "runtimes.routes pattern '\(pattern)' must be RabinApps/name@Workflow or RabinApps/name")
                    }
                } else {
                    guard segments.count == 2, segments.allSatisfy({ !$0.isEmpty }) else {
                        throw ConfigError.invalid(
                            "runtimes.routes pattern '\(pattern)' must be RabinApps/name (or RabinApps/name@Workflow)")
                    }
                }
                routes.append(kinhinConfig.RuntimeConfig.Route(pattern: pattern, runtime: runtime))
            }
            var seenPatterns: Set<String> = []
            for route in routes where !seenPatterns.insert(route.pattern).inserted {
                throw ConfigError.invalid("duplicate runtimes.routes pattern '\(route.pattern)'")
            }
            let referenced = Set(budget.keys).union(routes.map(\.runtime)).union([runtimes.default ?? "tart"])
            let validRuntimes = Set(["tart", "appleContainer", "docker"])
            for name in referenced where !validRuntimes.contains(name) {
                throw ConfigError.invalid("runtimes: unknown runtime '\(name)' (known: tart, appleContainer, docker)")
            }
            if referenced.contains("appleContainer"), cfg.container == nil {
                throw ConfigError.invalid(
                    "runtimes routes reference 'appleContainer' but no container: section is configured (it needs an image)"
                )
            }
            if referenced.contains("docker"), cfg.docker == nil {
                throw ConfigError.invalid(
                    "runtimes routes reference 'docker' but no docker: section is configured (it needs an image)")
            }
            let totalWeight = budget.values.reduce(0, +)
            guard totalWeight <= 1.0001 else {
                throw ConfigError.invalid(
                    "runtimes.budget weights sum to \(String(format: "%.2f", totalWeight)) — the total must be <= 1.0")
            }
            cfg.runtimes = kinhinConfig.RuntimeConfig(
                defaultRuntime: runtimes.default ?? "tart",
                budget: budget,
                routes: routes
            )
        }
        if let reserve = partial.reserve {
            if let cpu = reserve.cpu {
                guard cpu >= 0 else { throw ConfigError.invalid("reserve.cpu must be >= 0") }
                cfg.reserve.cpu = cpu
            }
            if let mem = reserve.memory_gb {
                guard mem >= 0 else { throw ConfigError.invalid("reserve.memory_gb must be >= 0") }
                cfg.reserve.memoryGB = mem
            }
        }
        return cfg
    }

    // MARK: Toolchains section

    /// Validates and resolves the `toolchains:` section. Beyond the usual
    /// shape checks (non-empty entries, no duplicates per list, non-negative
    /// cache values) this enforces the no-implicit-installs rule: a stack
    /// that needs a runtime (e.g. vercel → node) fails validation naming the
    /// fix, instead of silently installing the dependency.
    ///
    /// Public so the CLI can validate `image prepare --toolchain/--stack`
    /// flag overrides through the exact same rules as config parsing.
    public static func parseToolchains(_ partial: PartialConfig.PartialToolchains) throws
        -> kinhinConfig.ToolchainsConfig
    {
        let specs = try Self.parseList(partial.specs, key: "toolchains.specs")
        let brew = try Self.parseList(partial.brew, key: "toolchains.brew")
        let stackNames = try Self.parseList(partial.stacks, key: "toolchains.stacks")

        var toolchains = kinhinConfig.ToolchainsConfig(
            specs: partial.specs != nil ? specs : nil,
            brew: partial.brew != nil ? brew : nil,
            stacks: partial.stacks != nil ? stackNames : nil,
            shareCache: partial.share_cache,
            cache: nil
        )

        if let cache = partial.cache {
            if let auto = cache.auto_prune, auto == false, cache.max_age_days == nil, cache.max_gb == nil {
                throw ConfigError.invalid(
                    "toolchains.cache: set auto_prune: false together with explicit max_age_days / max_gb values, or remove the cache section (the defaults are auto_prune: true, 30 days, 50 GB)"
                )
            }
            if let days = cache.max_age_days, days < 0 {
                throw ConfigError.invalid("toolchains.cache.max_age_days must be >= 0 (0 = no age limit)")
            }
            if let gb = cache.max_gb, gb < 0 {
                throw ConfigError.invalid("toolchains.cache.max_gb must be >= 0 (0 = no size limit)")
            }
            toolchains.cache = kinhinConfig.ToolchainsConfig.CachePolicy(
                autoPrune: cache.auto_prune,
                maxAgeDays: cache.max_age_days,
                maxGB: cache.max_gb
            )
        }

        // Stack ids must be known, and their runtime prerequisites must be
        // explicitly selected. Unknown specs/brew entries stay legal (pass-
        // through); stacks are kinhin-curated so an unknown id is a typo.
        var resolvedStacks: [ToolchainStack] = []
        for name in stackNames {
            let (id, _) = ToolchainStack.splitSpec(name)
            guard let stack = ToolchainCatalog.stack(id: id) else {
                throw ConfigError.invalid(
                    "toolchains.stacks: unknown stack '\(id)' (known: \(ToolchainCatalog.stacks.map(\.id).joined(separator: ", ")))"
                )
            }
            resolvedStacks.append(stack)
        }

        // No implicit installs: each stack's runtime requirements must be
        // selected explicitly. `dotnet` in specs is the C#/.NET toolchain;
        // `node` covers every node-family entry.
        let specRoots = Set(specs.map { ToolchainCatalog.rootTool(of: $0) })
        for stack in resolvedStacks {
            for requirement in stack.requires {
                let satisfied: Bool
                switch requirement {
                case .node: satisfied = specRoots.contains("node")
                case .dotnet: satisfied = specRoots.contains("dotnet")
                }
                guard satisfied else {
                    throw ConfigError.invalid(
                        "toolchains: stack '\(stack.id)' requires \(requirement.rawValue) — add it to toolchains.specs (e.g. \"node@22\")"
                    )
                }
            }
        }

        // Same no-implicit-installs rule for individual tools that need a
        // runtime (pnpm, yarn, playwright, cypress, netlify-cli, …).
        for spec in specs {
            let root = ToolchainCatalog.rootTool(of: spec)
            guard let tool = ToolchainCatalog.tool(id: root), !tool.requires.isEmpty else { continue }
            for requirement in tool.requires {
                let satisfied: Bool
                switch requirement {
                case .node: satisfied = specRoots.contains("node")
                case .dotnet: satisfied = specRoots.contains("dotnet")
                }
                guard satisfied else {
                    throw ConfigError.invalid(
                        "toolchains: '\(root)' requires \(requirement.rawValue) — add it to toolchains.specs (e.g. \"node@22\")"
                    )
                }
            }
        }

        return toolchains
    }

    /// Shared list parsing: every entry non-empty, no duplicates, list must
    /// not be all-whitespace. Returns [] for an absent list.
    static func parseList(_ raw: [String]?, key: String) throws -> [String] {
        guard let raw else { return [] }
        var seen = Set<String>()
        for entry in raw {
            let trimmed = entry.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else {
                throw ConfigError.invalid("\(key) entries must not be empty")
            }
            guard seen.insert(trimmed).inserted else {
                throw ConfigError.invalid("\(key): duplicate entry '\(trimmed)'")
            }
        }
        return raw
    }

    /// The commented default template written by `kinhin config init`.
    public static func template() -> String {
        """
        # kinhin configuration
        # Location: ~/Library/Application Support/Kinhin/config.yaml
        # (Upgrading from the pre-rename Orchard build? Your config, logs,
        # and Keychain tokens migrate automatically on first launch.)

        # GitHub scope to serve (required). Jobs whose `runs-on:` matches
        # (subset of) `labels` below will be run here.
        #   "RabinApps/name"  → a single repository
        #   "your-org"    → an entire organization (org-level runners serve
        #                   every repo's queued jobs; the PAT needs org
        #                   runner-management permissions)
        repo: "your-org/your-repo"

        # Labels jobs must request to be picked up by this fleet.
        labels: ["self-hosted", "macos", "arm64"]

        # Concurrency bounds. kinhin scales between these based on queued work.
        min_runners: 0
        max_runners: 2

        # Runner processes per VM (many-to-one): each VM serves this many jobs
        # at once. 1 = one job per VM (default, most isolated). 2-3 works for
        # Xcode jobs on an 8 GB VM; higher densities suit lightweight jobs.
        runners_per_vm: 1

        # How often to ask GitHub about queued jobs (seconds, >= 5).
        poll_interval: 20

        # Per-VM resources. Keep total within your Mac's capacity — see
        # `kinhin doctor` for the computed budget.
        vm:
          cpu: 4          # vCPUs per runner VM
          memory_gb: 8    # RAM per runner VM
          ephemeral: true # fresh VM per job (recommended)

        # Tart image to clone. Prepare it first with: kinhin image prepare
        image: "tahoe-base"

        # Seconds a freshly booted VM has to register as a runner.
        vm_boot_timeout: 300

        # Host headroom kept free so your Mac stays responsive.
        reserve:
          cpu: 2
          memory_gb: 4

        # Optional overrides:
        # disk_gb: 0           # extra scratch disk per VM
        # tart_path: /opt/homebrew/bin/tart
        # token_ttl: 3000      # seconds to cache the runner registration token

        # Optional: bake your own toolchains into the base image. The script
        # runs (verbatim, as the admin user) inside the VM during
        # `kinhin image prepare`, after the runner agents are installed;
        # every runner VM then boots with whatever it installs. The script is
        # the version pin — edit it and re-run prepare to change toolchains.
        # The base image ships Homebrew and mise, so either works:
        #   brew install wget go@1.23 temurin@21
        #   mise install go@1.23.4 rust@1.82 java@temurin-21
        # End the script with `go version && java -version` prints — their
        # output is logged, recording what went into the image.
        # provision_script: "~/kinhin/provision.sh"

        # Optional: managed toolchains — kinhin installs and pins the
        # runtimes below into the base image (no script to write), with
        # version prints logged as the audit trail. Every entry installs
        # exactly its own pieces; a stack that needs a runtime (vercel needs
        # node) is a validation error until you list that runtime too.
        # Unknown specs pass through to mise, unknown brew entries to brew —
        # see `kinhin toolchains` for the curated catalog.
        # toolchains:
        #   specs: ["go@1.23.4", "node@22", "bun@1.1.27", "deno@2", "java@temurin-17", "dotnet", "uv"]
        #   brew: ["wget", "cmake", "yamllint"]
        #   stacks: ["flutter@3.24.0", "expo", "react-native", "vercel", "cloudflare"]
        #   share_cache: false   # mount the host download cache into runner VMs (opt-in)
        #   cache:               # host-side cache auto-expiry (baked images are never touched)
        #     auto_prune: true   # sweep after each prepare + daily while the fleet runs
        #     max_age_days: 30   # entries unused this long are deleted (0 = never)
        #     max_gb: 50         # LRU eviction beyond this size (0 = unlimited)

        # Optional: also serve Gitea Actions from the same fleet. VMs are
        # assigned to whichever forge (GitHub or Gitea) has the most pending
        # work at spawn time. Requires a Gitea access token (kinhin auth set
        # --gitea) with runner-management rights on the scope below.
        # gitea:
        #   instance: "https://gitea.example.com"
        #   scope: "RabinApps/name"        # or an org name
        #   labels: ["macos:host"]     # jobs opt in via runs-on: macos:host

        # Optional: route repos and workflows to different execution runtimes.
        # macOS jobs need Tart VMs; Linux jobs can run in Apple-container
        # microVMs (cheaper per job). Each runtime's runners carry distinct
        # labels, so a workflow overrides its repo's route per job via
        # `runs-on:` (e.g. runs-on: [kinhin-container]).
        # runtimes:
        #   default: tart                # runtime for repos with no route
        #   budget: {tart: 0.6, appleContainer: 0.4}   # host-budget split
        #   routes:
        #     - pattern: "acme/ios-app"
        #       runtime: tart
        #     - pattern: "acme/api"
        #       runtime: appleContainer
        #     - pattern: "acme/web@Linux-only checks"   # per-workflow route
        #       runtime: appleContainer

        # Optional: run Linux jobs in Apple `container` microVMs instead of
        # full Tart VMs (github.com/apple/container — lightweight, one VM per
        # container, Apple silicon only). Much cheaper per job for Linux
        # workloads; macOS jobs still need Tart. Requires the container CLI
        # (brew install container) and a Linux image baked with the
        # runner agents — prepare it with: kinhin image prepare --container-image <name>
        # container:
        #   image: "kinhin-ci-linux"
        #   cpus: 4
        #   memory_gb: 8

        # Optional: run Linux jobs in Docker containers inside your Docker
        # provider's shared Linux VM (Docker Desktop, OrbStack, or colima).
        # kinhin delegates the VM to the provider — it only runs one runner
        # container per job slot. Requires Docker running and a Linux image
        # baked with the runner agents: kinhin image prepare --docker
        # docker:
        #   image: "kinhin-ci-linux"
        #   cpus: 2
        #   memory_gb: 4
        #   max_slots: 8   # hard cap on concurrent runner containers
        """
    }
}

/// Decode target mirroring kinhinConfig but with all fields optional so we
/// can produce precise validation errors instead of opaque decode failures.
/// Public because the toolchains validation entry (`parseToolchains`) takes
/// a `PartialToolchains` — the CLI's flag overrides reuse the same rules.
public struct PartialConfig: Decodable {
    var repo: String?
    var labels: [String]?
    var min_runners: Int?
    var max_runners: Int?
    var runners_per_vm: Int?
    var poll_interval: Int?
    var token_ttl: Int?
    var vm: PartialVM?
    var image: String?
    var vm_boot_timeout: Int?
    var disk_gb: Int?
    var tart_path: String?
    var reserve: PartialReserve?
    var gitea: PartialGitea?
    var container: PartialContainer?
    var docker: PartialDocker?
    var runtimes: PartialRuntimes?
    var provision_script: String?
    var toolchains: PartialToolchains?

    struct PartialGitea: Decodable {
        var instance: String?
        var scope: String?
        var labels: [String]?
    }

    struct PartialVM: Decodable {
        var cpu: Int?
        var memory_gb: Int?
        var ephemeral: Bool?
    }

    struct PartialContainer: Decodable {
        var image: String?
        var cpus: Int?
        var memory_gb: Int?
        var labels: [String]?
    }

    struct PartialDocker: Decodable {
        var image: String?
        var cpus: Int?
        var memory_gb: Int?
        var max_slots: Int?
    }

    struct PartialRuntimes: Decodable {
        var `default`: String?
        var budget: [String: Double]?
        var routes: [PartialRoute]?
    }

    struct PartialRoute: Decodable {
        var pattern: String?
        var runtime: String?
    }

    struct PartialReserve: Decodable {
        var cpu: Int?
        var memory_gb: Int?
    }

    /// Public because `ConfigLoader.parseToolchains` (the shared validation
    /// entry the CLI uses for `--toolchain/--stack` overrides) exposes it.
    public struct PartialToolchains: Decodable {
        public var specs: [String]?
        public var brew: [String]?
        public var stacks: [String]?
        public var share_cache: Bool?
        public var cache: PartialCachePolicy?

        public init(
            specs: [String]? = nil, brew: [String]? = nil, stacks: [String]? = nil, share_cache: Bool? = nil,
            cache: PartialCachePolicy? = nil
        ) {
            self.specs = specs
            self.brew = brew
            self.stacks = stacks
            self.share_cache = share_cache
            self.cache = cache
        }
    }

    public struct PartialCachePolicy: Decodable {
        public var auto_prune: Bool?
        public var max_age_days: Int?
        public var max_gb: Int?

        public init(auto_prune: Bool? = nil, max_age_days: Int? = nil, max_gb: Int? = nil) {
            self.auto_prune = auto_prune
            self.max_age_days = max_age_days
            self.max_gb = max_gb
        }
    }
}
