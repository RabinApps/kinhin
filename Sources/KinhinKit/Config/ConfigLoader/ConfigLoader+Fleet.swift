import Foundation

// MARK: - Fleet-wide sections (labels, scaling, vm, image, reserve)

extension ConfigLoader {
    /// Accepted `token_ttl` seconds. GitHub registration tokens live one hour.
    static let tokenTTLRange = 60...3600
    /// Accepted `vm_boot_timeout` seconds: below 30 no VM can boot and join; above an hour a stuck boot holds a slot.
    static let vmBootTimeoutRange = 30...3600

    static func parseLabels(_ provided: [String]?) throws -> [String] {
        guard let provided else { return KinhinConfig.default.labels }
        guard !provided.isEmpty else { throw ConfigError.invalid("labels must not be empty") }
        return provided
    }

    /// `min_runners`, `max_runners`, `runners_per_vm`, `poll_interval`, `auto_resume`, `token_ttl`.
    static func parseScaling(_ partial: PartialConfig, into cfg: inout KinhinConfig) throws {
        // Absent keys take `KinhinConfig.default`, the one source of truth for defaults.
        let defaults = KinhinConfig.default
        let minRunners = partial.minRunners ?? defaults.minRunners
        let maxRunners = partial.maxRunners ?? defaults.maxRunners
        if minRunners < 0 { throw ConfigError.invalid("min_runners must be >= 0") }
        if maxRunners < 1 { throw ConfigError.invalid("max_runners must be >= 1") }
        if maxRunners < minRunners {
            throw ConfigError.invalid("max_runners (\(maxRunners)) must be >= min_runners (\(minRunners))")
        }
        let runnersPerVM = partial.runnersPerVM ?? defaults.runnersPerVM
        if runnersPerVM < 1 { throw ConfigError.invalid("runners_per_vm must be >= 1") }
        if runnersPerVM > 8 {
            throw ConfigError.invalid("runners_per_vm must be <= 8 (each runner shares the VM's CPU and RAM)")
        }
        let poll = partial.pollInterval ?? defaults.pollInterval
        if poll < 5 {
            throw ConfigError.invalid(
                "poll_interval must be >= 5 seconds (polling faster risks hitting the forge API rate limits)")
        }
        cfg.minRunners = minRunners
        cfg.maxRunners = maxRunners
        cfg.runnersPerVM = runnersPerVM
        cfg.pollInterval = poll
        cfg.autoResume = partial.autoResume ?? defaults.autoResume
        if let ttl = partial.tokenTTL {
            guard Self.tokenTTLRange.contains(ttl) else {
                throw ConfigError.invalid(
                    "token_ttl must be between \(Self.tokenTTLRange.lowerBound) and \(Self.tokenTTLRange.upperBound) "
                        + "seconds (registration tokens expire after one hour), got \(ttl)")
            }
            cfg.tokenTTL = ttl
        }
    }

    static func parseVM(_ vm: PartialConfig.PartialVM?, into cfg: inout KinhinConfig) throws {
        guard let vm else { return }
        if let cpu = vm.cpu, cpu < 1 { throw ConfigError.invalid("vm.cpu must be >= 1") }
        if let mem = vm.memoryGB, mem < 2 { throw ConfigError.invalid("vm.memory_gb must be >= 2") }
        if let e = vm.ephemeral { cfg.vm.ephemeral = e }
        if let cpu = vm.cpu { cfg.vm.cpuCount = cpu }
        if let mem = vm.memoryGB { cfg.vm.memoryGB = mem }
    }

    /// `image`, `base_image`, `images`, `vm_boot_timeout`, `disk_gb`, `tart_path`,
    /// `tart_softnet`, `provision_script`: everything about the Tart VM images.
    static func parseImageSettings(_ partial: PartialConfig, into cfg: inout KinhinConfig) throws {
        if let image = partial.image {
            guard !image.isEmpty else { throw ConfigError.invalid("image must not be empty") }
            cfg.image = image
        }
        if let baseImage = partial.baseImage {
            if let problem = TartBaseImage.problem(with: baseImage) {
                throw ConfigError.invalid("base_image \(problem)")
            }
            cfg.baseImage = baseImage
        }
        if let images = partial.images {
            cfg.images = try Self.parseImages(images, primary: cfg.image, fleetLabels: cfg.labels)
        }
        if let boot = partial.vmBootTimeout {
            guard Self.vmBootTimeoutRange.contains(boot) else {
                throw ConfigError.invalid(
                    "vm_boot_timeout must be between \(Self.vmBootTimeoutRange.lowerBound) and "
                        + "\(Self.vmBootTimeoutRange.upperBound) seconds, got \(boot)")
            }
            cfg.vmBootTimeout = boot
        }
        if let disk = partial.diskGB {
            guard disk >= 0 else { throw ConfigError.invalid("disk_gb must be >= 0") }
            cfg.diskGB = disk
        }
        if let tartPath = partial.tartPath { cfg.tartPath = tartPath }
        if let softnet = partial.tartSoftnet { cfg.tartSoftnet = softnet }
        if let provision = partial.provisionScript {
            guard !provision.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw ConfigError.invalid(
                    "provision_script must not be empty (remove the key or point it at a script file)")
            }
            cfg.provisionScript = provision
        }
    }

    /// `toolchain_cache`, `max_project_images`, `projects`.
    static func parseToolchainSettings(_ partial: PartialConfig, into cfg: inout KinhinConfig) throws {
        if let cache = partial.toolchainCache {
            cfg.toolchainCache = try Self.parseToolchainCache(cache)
        }
        if let maxImages = partial.maxProjectImages {
            guard maxImages >= 1 else { throw ConfigError.invalid("max_project_images must be >= 1") }
            cfg.maxProjectImages = maxImages
        }
        if let projects = partial.projects {
            cfg.projects = try Self.parseProjects(projects)
        }
    }

    static func parseReserve(_ reserve: PartialConfig.PartialReserve?, into cfg: inout KinhinConfig) throws {
        guard let reserve else { return }
        if let cpu = reserve.cpu {
            guard cpu >= 0 else { throw ConfigError.invalid("reserve.cpu must be >= 0") }
            cfg.reserve.cpu = cpu
        }
        if let mem = reserve.memoryGB {
            guard mem >= 0 else { throw ConfigError.invalid("reserve.memory_gb must be >= 0") }
            cfg.reserve.memoryGB = mem
        }
        if let disk = reserve.diskGB {
            guard disk >= 0 else { throw ConfigError.invalid("reserve.disk_gb must be >= 0") }
            cfg.reserve.diskGB = disk
        }
    }

    /// Removed keys: decoded only so they can be rejected with a pointer to
    /// their replacement instead of being silently ignored.
    static func rejectRemovedKeys(_ partial: PartialConfig) throws {
        if partial.toolchains != nil {
            throw ConfigError.invalid(
                "toolchains: is gone — every project declares its own: projects: "
                    + "[{pattern: owner/name, toolchains: {specs: [go@1.23.4]}}], or let the repo declare them in a "
                    + ".kinhin.yml (projects: [{pattern: owner/name, repo_file: true}]). The cache policy moved to toolchain_cache:. \(ConfigMigrator.hint)"
            )
        }
        if partial.repo != nil {
            throw ConfigError.invalid(
                "repo: is gone — declare the forge as an accounts: entry: "
                    + "accounts: [{name: github, forge: github, scope: owner/name}]. \(ConfigMigrator.hint)")
        }
        if partial.gitea != nil || partial.forgejo != nil {
            throw ConfigError.invalid(
                "gitea:/forgejo: are gone — declare each forge as an accounts: entry "
                    + "(accounts: [{name: gitea, forge: gitea, scope: ..., instance: ...}]). \(ConfigMigrator.hint)")
        }
    }
}
