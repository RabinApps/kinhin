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
        let warmPool = partial.warmPool ?? defaults.warmPool
        if warmPool < 0 { throw ConfigError.invalid("warm_pool must be >= 0") }
        if warmPool > maxRunners {
            throw ConfigError.invalid("warm_pool (\(warmPool)) must be <= max_runners (\(maxRunners))")
        }
        let warmMaxAge = partial.warmMaxAgeMinutes ?? defaults.warmMaxAgeMinutes
        if warmMaxAge < 5 { throw ConfigError.invalid("warm_max_age_minutes must be >= 5") }
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
        cfg.warmPool = warmPool
        cfg.warmMaxAgeMinutes = warmMaxAge
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
        if let imageLabels = partial.imageLabels {
            cfg.imageLabels = try Self.validatedImageLabels(
                imageLabels, fleetLabels: cfg.labels, images: cfg.images,
                linuxBase: TartBaseImage.isLinux(cfg.baseImage))
        }
        // Warm VMs take slots under max_runners, so the base and every image's warm_pool share that ceiling.
        for image in cfg.images where image.warmPool > cfg.maxRunners {
            throw ConfigError.invalid(
                "images: \(image.name) warm_pool (\(image.warmPool)) must be <= max_runners (\(cfg.maxRunners))")
        }
        let warmTotal = cfg.warmPool + cfg.images.reduce(0) { $0 + $1.warmPool }
        if warmTotal > cfg.maxRunners {
            throw ConfigError.invalid(
                "warm_pool across the base image and images: (\(warmTotal)) must be <= max_runners (\(cfg.maxRunners))")
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

    /// `healing:`: every key optional, defaults from `HealingConfig`.
    static func parseHealing(_ partial: PartialConfig.PartialHealing) throws -> KinhinConfig.HealingConfig {
        var healing = KinhinConfig.HealingConfig.default
        if let enabled = partial.enabled { healing.enabled = enabled }
        if let auto = partial.auto {
            guard let mode = KinhinConfig.HealingConfig.AutoMode(rawValue: auto) else {
                throw ConfigError.invalid("healing.auto must be safe or none, got '\(auto)'")
            }
            healing.auto = mode
        }
        if let ai = partial.ai {
            guard let mode = KinhinConfig.HealingConfig.AIMode(rawValue: ai) else {
                throw ConfigError.invalid("healing.ai must be auto, off or ollama, got '\(ai)'")
            }
            healing.ai = mode
        }
        if let attempts = partial.maxAttempts {
            let range = KinhinConfig.HealingConfig.maxAttemptsRange
            guard range.contains(attempts) else {
                throw ConfigError.invalid(
                    "healing.max_attempts must be between \(range.lowerBound) and \(range.upperBound), got \(attempts)")
            }
            healing.maxAttempts = attempts
        }
        switch (healing.ai, partial.ollama) {
        case (.ollama, let block?):
            healing.ollama = try parseOllama(block)
        case (.ollama, nil):
            throw ConfigError.invalid("healing.ai: ollama needs a healing.ollama block with a model")
        case (_, .some):
            throw ConfigError.invalid("healing.ollama is only used with healing.ai: ollama")
        case (_, nil):
            break
        }
        return healing
    }

    /// `healing.ollama:`: the model is required; the host must be a URL, and
    /// one that is not this Mac must be https, so logs never cross the network
    /// in cleartext. The fast model, if any, must be a different model.
    static func parseOllama(
        _ partial: PartialConfig.PartialHealing.PartialOllama
    ) throws -> KinhinConfig.HealingConfig.OllamaConfig {
        guard let model = partial.model?.trimmingCharacters(in: .whitespaces), !model.isEmpty else {
            throw ConfigError.invalid("healing.ollama.model is required with healing.ai: ollama")
        }
        var host = KinhinConfig.HealingConfig.OllamaConfig.defaultHost
        if let raw = partial.host {
            guard let url = URL(string: raw), let scheme = url.scheme?.lowercased(), url.host != nil,
                scheme == "http" || scheme == "https"
            else {
                throw ConfigError.invalid("healing.ollama.host must be an http or https URL, got '\(raw)'")
            }
            if scheme != "https" && !KinhinConfig.HealingConfig.OllamaConfig.isLoopback(url) {
                throw ConfigError.invalid(
                    "healing.ollama.host must use https unless it is this Mac (localhost, 127.0.0.1 or ::1)")
            }
            host = url
        }
        let fast = partial.fastModel?.trimmingCharacters(in: .whitespaces)
        if fast?.isEmpty == true {
            throw ConfigError.invalid("healing.ollama.fast_model is empty; remove it to use the LLM alone")
        }
        if fast == model {
            throw ConfigError.invalid("healing.ollama.fast_model must be a different model from healing.ollama.model")
        }
        let keepAlive =
            partial.keepAlive?.trimmingCharacters(in: .whitespaces)
            ?? KinhinConfig.HealingConfig.OllamaConfig.defaultKeepAlive
        if keepAlive.isEmpty {
            throw ConfigError.invalid("healing.ollama.keep_alive is empty; use a duration such as 30m, or 0")
        }
        return KinhinConfig.HealingConfig.OllamaConfig(
            host: host, model: model, fastModel: fast, keepAlive: keepAlive)
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

// MARK: - Telemetry

extension ConfigLoader {
    /// `telemetry:`: every key optional, defaults from `TelemetryConfig` (off).
    static func parseTelemetry(_ partial: PartialConfig.PartialTelemetry) throws -> KinhinConfig.TelemetryConfig {
        typealias Telemetry = KinhinConfig.TelemetryConfig
        var telemetry = Telemetry.default
        if let enabled = partial.enabled { telemetry.enabled = enabled }
        if let raw = partial.endpoint {
            telemetry.endpoint = try validateTelemetryEndpoint(raw, key: "telemetry.endpoint")
        }
        if let raw = partial.otlpProtocol {
            guard let proto = Telemetry.OTLPProtocol(rawValue: raw) else {
                throw ConfigError.invalid("telemetry.protocol must be http/protobuf or grpc, got '\(raw)'")
            }
            telemetry.otlpProtocol = proto
        }
        // `export_interval` is accepted as an alias of `export_interval_seconds` (the key the docs use).
        if let one = partial.exportInterval, let two = partial.exportIntervalAlias, one != two {
            throw ConfigError.invalid(
                "telemetry.export_interval and telemetry.export_interval_seconds disagree; keep export_interval_seconds"
            )
        }
        if let interval = partial.exportInterval ?? partial.exportIntervalAlias {
            let range = Telemetry.exportIntervalRange
            guard range.contains(interval) else {
                throw ConfigError.invalid(
                    "telemetry.export_interval_seconds must be between \(range.lowerBound) and \(range.upperBound) seconds, got \(interval)"
                )
            }
            telemetry.exportIntervalSeconds = interval
        }
        if let names = partial.signals {
            var signals = Set<Telemetry.Signal>()
            for name in names {
                guard let signal = Telemetry.Signal(rawValue: name) else {
                    throw ConfigError.invalid(
                        "telemetry.signals entries must be metrics, traces or logs, got '\(name)'")
                }
                signals.insert(signal)
            }
            telemetry.signals = signals
        }
        if let names = partial.jobAttributes {
            var attributes = Set<Telemetry.JobAttribute>()
            for name in names {
                guard let attribute = Telemetry.JobAttribute(rawValue: name) else {
                    throw ConfigError.invalid(
                        "telemetry.job_attributes entries must be repository or workflow, got '\(name)'")
                }
                attributes.insert(attribute)
            }
            telemetry.jobAttributes = attributes
        }
        if let attributes = partial.resourceAttributes {
            for key in attributes.keys.sorted() {
                guard !key.isEmpty, !key.contains(where: \.isWhitespace) else {
                    throw ConfigError.invalid("telemetry.resource_attributes has an invalid key '\(key)'")
                }
                if Telemetry.isReservedResourceKey(key) {
                    throw ConfigError.invalid(
                        "telemetry.resource_attributes cannot set '\(key)': kinhin owns the service identity "
                            + "(service.name, service.version, telemetry.sdk.*)")
                }
            }
            telemetry.resourceAttributes = attributes
        }
        if let raw = partial.prometheusListen {
            guard TelemetryListenAddress(parsing: raw) != nil else {
                throw ConfigError.invalid(
                    "telemetry.prometheus_listen must be a port or host:port (for example 127.0.0.1:9464), got '\(raw)'"
                )
            }
            telemetry.prometheusListen = raw.trimmingCharacters(in: .whitespaces)
        }
        if let raw = partial.logFormat {
            guard let format = Telemetry.LogFormat(rawValue: raw) else {
                throw ConfigError.invalid("telemetry.log_format must be text or json, got '\(raw)'")
            }
            telemetry.logFormat = format
        }
        try parseTelemetryExporterKeys(partial, into: &telemetry)
        if telemetry.prometheusListen != nil, !telemetry.signals.contains(.metrics) {
            throw ConfigError.invalid("telemetry.prometheus_listen serves metrics: add 'metrics' to telemetry.signals")
        }
        return telemetry
    }

    /// An OTLP endpoint is an http(s) URL with a host.
    static func validateTelemetryEndpoint(_ raw: String, key: String) throws -> String {
        guard telemetryEndpointURL(raw) != nil else {
            throw ConfigError.invalid("\(key) must be an http or https URL, got '\(raw)'")
        }
        return raw.trimmingCharacters(in: .whitespaces)
    }

    /// The URL of an OTLP endpoint text, or nil when it is not an http(s) URL with a host.
    static func telemetryEndpointURL(_ raw: String) -> URL? {
        let trimmed = raw.trimmingCharacters(in: .whitespaces)
        guard let url = URL(string: trimmed), let scheme = url.scheme?.lowercased(),
            scheme == "http" || scheme == "https", let host = url.host, !host.isEmpty
        else { return nil }
        return url
    }
}
