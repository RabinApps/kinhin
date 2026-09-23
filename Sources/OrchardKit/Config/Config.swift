import Foundation
import Yams

/// User-facing configuration, loaded from `~/Library/Application Support/Orchard/config.yaml`.
public struct OrchardConfig: Sendable, Equatable {
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

    /// GitHub repository to serve, e.g. "acme/widgets".
    public var repo: String
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
    /// Tart image to clone for each runner, e.g. "tahoe-base" (prepared via `orchard image prepare`).
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

    public struct ContainerConfig: Sendable, Equatable {
        /// Linux OCI image to run each runner container from (must be
        /// prepared with the runner agents via `orchard image prepare`).
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
        /// workflows can opt in per job (`runs-on: [orchard-container]`).
        /// Always merged with "orchard-container" at pool construction.
        public var labels: [String]?

        enum CodingKeys: String, CodingKey {
            case image, cpus, labels
            case memoryGB = "memory_gb"
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
        /// Repo or `owner/repo@workflow` → runtime. Repo routes take
        /// precedence over workflow routes; first matching route wins.
        public var routes: [Route]

        public struct Route: Sendable, Equatable {
            /// "owner/name" or "owner/name@Workflow Name".
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

        public init(defaultRuntime: String = RuntimeID.tart.rawValue, budget: [String: Double] = [:], routes: [Route] = []) {
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
        case runtimes
    }

    public static let `default` = OrchardConfig(
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
        runtimes: nil
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
        case .notFound(let path): return "config not found at \(path) — run `orchard config init` to create one"
        case .unreadable(let path): return "config could not be read at \(path)"
        }
    }
}

/// Loads and validates `OrchardConfig`.
public struct ConfigLoader {
    public init() {}

    /// The repo value written by the starter template. A config containing it
    /// is a *template*, not a working config — the engine must refuse to run
    /// against it and the checklist must ask for a real repo instead of
    /// showing a green checkmark over a placeholder.
    public static let templateRepo = "your-org/your-repo"

    /// True when the parsed config still carries the template's placeholder repo.
    public static func isTemplate(_ cfg: OrchardConfig) -> Bool {
        cfg.repo == templateRepo
    }

    /// True when at least one forge is configured for real work.
    public static func hasAnyForge(_ cfg: OrchardConfig) -> Bool {
        !cfg.repo.isEmpty && cfg.repo != templateRepo
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

    public static func load(from url: URL = Paths.config) throws -> OrchardConfig {
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw ConfigError.notFound(url.path)
        }
        guard let yaml = try? String(contentsOf: url, encoding: .utf8) else {
            throw ConfigError.unreadable(url.path)
        }
        return try Self.parse(yaml)
    }

    public static func parse(_ yaml: String) throws -> OrchardConfig {
        let partial = try YAMLDecoder().decode(PartialConfig.self, from: yaml)

        guard let repo = partial.repo, !repo.isEmpty else {
            throw ConfigError.missing("repo")
        }
        // Scope: "owner/name" (one repository) or a single segment (an org —
        // org-level runners serve every repo in the organization).
        let scopeSegments = repo.split(separator: "/")
        guard (1 ... 2).contains(scopeSegments.count),
              scopeSegments.allSatisfy({ !$0.isEmpty }) else {
            throw ConfigError.invalid("scope must be 'owner/name' or an org name, got '\(repo)'")
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
        if poll < 5 { throw ConfigError.invalid("poll_interval must be >= 5 seconds to stay within GitHub rate limits") }

        var cfg = OrchardConfig.default
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
        if let gitea = partial.gitea {
            guard let instance = gitea.instance, !instance.isEmpty else {
                throw ConfigError.invalid("gitea.instance is required (e.g. https://gitea.example.com)")
            }
            guard (try? GiteaCredentials.validate(instance: instance)) != nil else {
                throw ConfigError.invalid("gitea.instance must be a base URL like https://gitea.example.com (no path, no /api suffix)")
            }
            guard let scope = gitea.scope, !scope.isEmpty else {
                throw ConfigError.invalid("gitea.scope is required ('owner/name' or an org name)")
            }
            let scopeSegments = scope.split(separator: "/")
            guard (1 ... 2).contains(scopeSegments.count),
                  scopeSegments.allSatisfy({ !$0.isEmpty }) else {
                throw ConfigError.invalid("gitea.scope must be 'owner/name' or an org name, got '\(scope)'")
            }
            if let giteaLabels = gitea.labels, giteaLabels.isEmpty {
                throw ConfigError.invalid("gitea.labels must be non-empty when present")
            }
            cfg.gitea = OrchardConfig.GiteaForgeConfig(instance: instance, scope: scope, labels: gitea.labels)
        }
        if let container = partial.container {
            guard let containerImage = container.image, !containerImage.isEmpty else {
                throw ConfigError.invalid("container.image must not be empty (a Linux OCI image baked with runner agents)")
            }
            if let cpus = container.cpus, cpus < 1 {
                throw ConfigError.invalid("container.cpus must be >= 1")
            }
            if let mem = container.memory_gb, mem < 2 {
                throw ConfigError.invalid("container.memory_gb must be >= 2")
            }
            cfg.container = OrchardConfig.ContainerConfig(
                image: containerImage,
                cpus: container.cpus ?? 4,
                memoryGB: container.memory_gb ?? 8,
                labels: container.labels
            )
        }
        if let runtimes = partial.runtimes {
            var budget: [String: Double] = [:]
            if let entries = runtimes.budget {
                for (runtime, weight) in entries {
                    guard weight > 0, weight <= 1 else {
                        throw ConfigError.invalid("runtimes.budget weights must be in (0, 1], got \(runtime): \(weight)")
                    }
                    budget[runtime] = weight
                }
            }
            var routes: [OrchardConfig.RuntimeConfig.Route] = []
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
                        throw ConfigError.invalid("runtimes.routes pattern '\(pattern)' must be owner/name@Workflow or owner/name")
                    }
                } else {
                    guard segments.count == 2, segments.allSatisfy({ !$0.isEmpty }) else {
                        throw ConfigError.invalid("runtimes.routes pattern '\(pattern)' must be owner/name (or owner/name@Workflow)")
                    }
                }
                routes.append(OrchardConfig.RuntimeConfig.Route(pattern: pattern, runtime: runtime))
            }
            var seenPatterns: Set<String> = []
            for route in routes where !seenPatterns.insert(route.pattern).inserted {
                throw ConfigError.invalid("duplicate runtimes.routes pattern '\(route.pattern)'")
            }
            let referenced = Set(budget.keys).union(routes.map(\.runtime)).union([runtimes.default ?? "tart"])
            let validRuntimes = Set(["tart", "appleContainer"])
            for name in referenced where !validRuntimes.contains(name) {
                throw ConfigError.invalid("runtimes: unknown runtime '\(name)' (known: tart, appleContainer)")
            }
            if referenced.contains("appleContainer"), cfg.container == nil {
                throw ConfigError.invalid("runtimes routes reference 'appleContainer' but no container: section is configured (it needs an image)")
            }
            let totalWeight = budget.values.reduce(0, +)
            guard totalWeight <= 1.0001 else {
                throw ConfigError.invalid("runtimes.budget weights sum to \(String(format: "%.2f", totalWeight)) — the total must be <= 1.0")
            }
            cfg.runtimes = OrchardConfig.RuntimeConfig(
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

    /// The commented default template written by `orchard config init`.
    public static func template() -> String {
        """
        # Orchard configuration
        # Location: ~/Library/Application Support/Orchard/config.yaml

        # GitHub scope to serve (required). Jobs whose `runs-on:` matches
        # (subset of) `labels` below will be run here.
        #   "owner/name"  → a single repository
        #   "your-org"    → an entire organization (org-level runners serve
        #                   every repo's queued jobs; the PAT needs org
        #                   runner-management permissions)
        repo: "your-org/your-repo"

        # Labels jobs must request to be picked up by this fleet.
        labels: ["self-hosted", "macos", "arm64"]

        # Concurrency bounds. Orchard scales between these based on queued work.
        min_runners: 0
        max_runners: 2

        # Runner processes per VM (many-to-one): each VM serves this many jobs
        # at once. 1 = one job per VM (default, most isolated). 2-3 works for
        # Xcode jobs on an 8 GB VM; higher densities suit lightweight jobs.
        runners_per_vm: 1

        # How often to ask GitHub about queued jobs (seconds, >= 5).
        poll_interval: 20

        # Per-VM resources. Keep total within your Mac's capacity — see
        # `orchard doctor` for the computed budget.
        vm:
          cpu: 4          # vCPUs per runner VM
          memory_gb: 8    # RAM per runner VM
          ephemeral: true # fresh VM per job (recommended)

        # Tart image to clone. Prepare it first with: orchard image prepare
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

        # Optional: also serve Gitea Actions from the same fleet. VMs are
        # assigned to whichever forge (GitHub or Gitea) has the most pending
        # work at spawn time. Requires a Gitea access token (orchard auth set
        # --gitea) with runner-management rights on the scope below.
        # gitea:
        #   instance: "https://gitea.example.com"
        #   scope: "owner/name"        # or an org name
        #   labels: ["macos:host"]     # jobs opt in via runs-on: macos:host

        # Optional: route repos and workflows to different execution runtimes.
        # macOS jobs need Tart VMs; Linux jobs can run in Apple-container
        # microVMs (cheaper per job). Each runtime's runners carry distinct
        # labels, so a workflow overrides its repo's route per job via
        # `runs-on:` (e.g. runs-on: [orchard-container]).
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
        # (brew install --cask container) and a Linux image baked with the
        # runner agents — prepare it with: orchard image prepare --container-image <name>
        # container:
        #   image: "orchard-ci-linux"
        #   cpus: 4
        #   memory_gb: 8
        """
    }
}

/// Decode target mirroring OrchardConfig but with all fields optional so we
/// can produce precise validation errors instead of opaque decode failures.
struct PartialConfig: Decodable {
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
    var runtimes: PartialRuntimes?

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
}
