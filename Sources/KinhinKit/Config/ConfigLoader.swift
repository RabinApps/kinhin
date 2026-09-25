import Foundation
import Yams

/// Loads and validates `KinhinConfig`.
public struct ConfigLoader {
    public init() {}

    /// The repo value written by the starter template. A config containing it
    /// is a *template*, not a working config — the engine must refuse to run
    /// against it and the checklist must ask for a real repo instead of
    /// showing a green checkmark over a placeholder.
    public static let templateRepo = "your-org/your-repo"

    /// True when the parsed config still carries the template's placeholder repo.
    static func isTemplate(_ cfg: KinhinConfig) -> Bool {
        cfg.repo == templateRepo
    }

    /// The GitHub token the engine is built with. With GitHub configured it is
    /// the Keychain PAT; if that is missing but a Gitea forge is configured
    /// with its own token, an empty placeholder lets the fleet run on Gitea
    /// alone (GitHub then reports its problem instead of blocking startup).
    /// Gitea-only configs also get the placeholder. Nil when no configured
    /// forge has a usable token.
    public static func engineToken(
        for cfg: KinhinConfig, load: (ForgeID) -> String? = { KeychainTokenStore.load(forge: $0) },
        loadAccount: (ForgeID, String) -> String? = { KeychainTokenStore.load(forge: $0, name: $1) }
    ) -> String? {
        let extraReady = cfg.accounts.contains { loadAccount($0.forge, $0.name) != nil }
        let giteaReady = extraReady || (cfg.gitea != nil && load(.gitea) != nil)
        if cfg.githubEnabled {
            if let token = load(.github) { return token }
            return giteaReady ? "" : nil
        }
        return giteaReady ? "" : nil
    }

    /// True when at least one forge is configured for real work.
    public static func hasAnyForge(_ cfg: KinhinConfig) -> Bool {
        cfg.githubEnabled || cfg.gitea != nil || !cfg.accounts.isEmpty
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

    public static func load(from url: URL = Paths.config) throws -> KinhinConfig {
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw ConfigError.notFound(url.path)
        }
        guard let yaml = try? String(contentsOf: url, encoding: .utf8) else {
            throw ConfigError.unreadable(url.path)
        }
        return try Self.parse(yaml)
    }

    /// `base_image:` is optional; when present it must be usable as a bare
    /// image reference (see `LinuxBaseImage.problem(with:)`).
    static func validatedBaseImage(_ value: String?, key: String) throws -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespaces)
        if let problem = LinuxBaseImage.problem(with: trimmed) {
            throw ConfigError.invalid("\(key) \(problem) (an image like ubuntu:24.04 or debian:12)")
        }
        return trimmed
    }

    /// Validates the `accounts:` list: unique tame names (not the legacy
    /// `github`/`gitea`), a known forge, a scope, and a Gitea instance URL.
    static func parseAccounts(_ entries: [PartialConfig.PartialAccount]) throws -> [AccountConfig] {
        var seen: Set<String> = []
        var result: [AccountConfig] = []
        for (index, entry) in entries.enumerated() {
            let position = "accounts[\(index)]"
            guard let name = entry.name, !name.isEmpty else {
                throw ConfigError.invalid("\(position).name is required")
            }
            guard AccountConfig.isValidName(name) else {
                throw ConfigError.invalid(
                    "\(position).name '\(name)' must be lowercase letters, digits, '-' or '_' (max 32)")
            }
            guard !AccountConfig.reservedNames.contains(name) else {
                throw ConfigError.invalid(
                    "\(position).name '\(name)' is reserved for the top-level repo:/gitea: sections — pick another name")
            }
            guard seen.insert(name).inserted else {
                throw ConfigError.invalid("duplicate account name '\(name)'")
            }
            guard let rawForge = entry.forge, let forge = ForgeID(rawValue: rawForge) else {
                throw ConfigError.invalid("account '\(name)': forge must be github or gitea")
            }
            guard let scope = entry.scope, AccountConfig.isValidScope(scope) else {
                throw ConfigError.invalid("account '\(name)': scope must be 'RabinApps/name' or an org name")
            }
            switch forge {
            case .github:
                if entry.instance != nil || entry.labels != nil {
                    throw ConfigError.invalid("account '\(name)': instance and labels apply to gitea accounts only")
                }
                result.append(AccountConfig(name: name, forge: forge, scope: scope))
            case .gitea:
                guard let instance = entry.instance, !instance.isEmpty else {
                    throw ConfigError.invalid("account '\(name)': instance is required (e.g. https://gitea.example.com)")
                }
                do {
                    _ = try GiteaCredentials.validate(instance: instance)
                } catch {
                    throw ConfigError.invalid(
                        "account '\(name)': instance must be a base URL like https://gitea.example.com (no path)")
                }
                if let labels = entry.labels, labels.isEmpty {
                    throw ConfigError.invalid("account '\(name)': labels must be non-empty when present")
                }
                result.append(AccountConfig(name: name, forge: forge, scope: scope, instance: instance, labels: entry.labels))
            }
        }
        return result
    }

    public static func parse(_ yaml: String) throws -> KinhinConfig {
        let partial = try YAMLDecoder().decode(PartialConfig.self, from: yaml)

        // `repo:` is the legacy GitHub account; it may be omitted when the
        // config names its accounts in the `accounts:` list instead.
        let accounts = try Self.parseAccounts(partial.accounts ?? [])
        let repo = partial.repo ?? ""
        if repo.isEmpty, accounts.isEmpty {
            throw ConfigError.missing("repo")
        }
        // Scope: "RabinApps/name" (one repository) or a single segment (an org —
        // org-level runners serve every repo in the organization).
        if !repo.isEmpty, !AccountConfig.isValidScope(repo) {
            throw ConfigError.invalid("scope must be 'RabinApps/name' or an org name, got '\(repo)'")
        }
        guard let labels = partial.labels, !labels.isEmpty else {
            throw ConfigError.missing("labels")
        }
        let minRunners = partial.minRunners ?? 0
        let maxRunners = partial.maxRunners ?? 1
        if minRunners < 0 { throw ConfigError.invalid("min_runners must be >= 0") }
        if maxRunners < 1 { throw ConfigError.invalid("max_runners must be >= 1") }
        if maxRunners < minRunners {
            throw ConfigError.invalid("max_runners (\(maxRunners)) must be >= min_runners (\(minRunners))")
        }
        let runnersPerVM = partial.runnersPerVM ?? 1
        if runnersPerVM < 1 { throw ConfigError.invalid("runners_per_vm must be >= 1") }
        if runnersPerVM > 8 {
            throw ConfigError.invalid("runners_per_vm must be <= 8 (each runner shares the VM's CPU and RAM)")
        }
        let poll = partial.pollInterval ?? 20
        if poll < 5 {
            throw ConfigError.invalid("poll_interval must be >= 5 seconds to stay within GitHub rate limits")
        }

        var cfg = KinhinConfig.default
        cfg.repo = repo
        cfg.accounts = accounts
        cfg.labels = labels
        cfg.minRunners = minRunners
        cfg.maxRunners = maxRunners
        cfg.runnersPerVM = runnersPerVM
        cfg.pollInterval = poll
        if let ttl = partial.tokenTTL { cfg.tokenTTL = ttl }
        if let vm = partial.vm {
            if let cpu = vm.cpu, cpu < 1 { throw ConfigError.invalid("vm.cpu must be >= 1") }
            if let mem = vm.memoryGB, mem < 2 { throw ConfigError.invalid("vm.memoryGB must be >= 2") }
            if let e = vm.ephemeral { cfg.vm.ephemeral = e }
            if let cpu = vm.cpu { cfg.vm.cpuCount = cpu }
            if let mem = vm.memoryGB { cfg.vm.memoryGB = mem }
        }
        if let image = partial.image {
            guard !image.isEmpty else { throw ConfigError.invalid("image must not be empty") }
            cfg.image = image
        }
        if let boot = partial.vmBootTimeout { cfg.vmBootTimeout = boot }
        if let disk = partial.diskGB {
            guard disk >= 0 else { throw ConfigError.invalid("disk_gb must be >= 0") }
            cfg.diskGB = disk
        }
        if let tartPath = partial.tartPath { cfg.tartPath = tartPath }
        if let provision = partial.provisionScript {
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
            do {
                _ = try GiteaCredentials.validate(instance: instance)
            } catch {
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
            cfg.gitea = KinhinConfig.GiteaForgeConfig(instance: instance, scope: scope, labels: gitea.labels)
        }
        if let container = partial.container {
            guard let containerImage = container.image, !containerImage.isEmpty else {
                throw ConfigError.invalid(
                    "container.image must not be empty (a Linux OCI image baked with runner agents)")
            }
            if let cpus = container.cpus, cpus < 1 {
                throw ConfigError.invalid("container.cpus must be >= 1")
            }
            if let mem = container.memoryGB, mem < 2 {
                throw ConfigError.invalid("container.memory_gb must be >= 2")
            }
            if container.platform != nil {
                throw ConfigError.invalid(
                    "container.platform is not supported: Apple container runs linux/arm64 only "
                        + "(docker.platform can select linux/amd64)")
            }
            let containerBase = try Self.validatedBaseImage(container.baseImage, key: "container.base_image")
            cfg.container = KinhinConfig.ContainerConfig(
                image: containerImage,
                cpus: container.cpus ?? 4,
                memoryGB: container.memoryGB ?? 8,
                labels: container.labels,
                baseImage: containerBase
            )
        }
        if let docker = partial.docker {
            guard let dockerImage = docker.image, !dockerImage.isEmpty else {
                throw ConfigError.invalid("docker.image must not be empty (a Linux OCI image baked with runner agents)")
            }
            if let cpus = docker.cpus, cpus < 1 {
                throw ConfigError.invalid("docker.cpus must be >= 1")
            }
            if let mem = docker.memoryGB, mem < 1 {
                throw ConfigError.invalid("docker.memory_gb must be >= 1")
            }
            if let slots = docker.maxSlots, slots < 1 {
                throw ConfigError.invalid("docker.max_slots must be >= 1")
            }
            let dockerBase = try Self.validatedBaseImage(docker.baseImage, key: "docker.base_image")
            var dockerPlatform = LinuxPlatform.arm64
            if let raw = docker.platform {
                guard let parsed = LinuxPlatform(configValue: raw) else {
                    throw ConfigError.invalid("docker.platform must be linux/arm64 or linux/amd64, got \"\(raw)\"")
                }
                dockerPlatform = parsed
            }
            cfg.docker = KinhinConfig.DockerForgeConfig(
                image: dockerImage,
                cpus: docker.cpus ?? 2,
                memoryGB: docker.memoryGB ?? 4,
                maxSlots: docker.maxSlots ?? 8,
                baseImage: dockerBase,
                platform: dockerPlatform
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
            var routes: [KinhinConfig.RuntimeConfig.Route] = []
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
                routes.append(KinhinConfig.RuntimeConfig.Route(pattern: pattern, runtime: runtime))
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
            cfg.runtimes = KinhinConfig.RuntimeConfig(
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
            if let mem = reserve.memoryGB {
                guard mem >= 0 else { throw ConfigError.invalid("reserve.memory_gb must be >= 0") }
                cfg.reserve.memoryGB = mem
            }
        }
        return cfg
    }
}
