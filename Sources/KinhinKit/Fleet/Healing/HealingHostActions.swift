import Foundation

/// The healing fixes and probes that reach outside the engine: Homebrew,
/// the container system, image and cache pruning, setup checks. Injected so
/// engine tests never run Homebrew or touch the real cache; production
/// wiring passes `.live`.
public struct HealingHostActions: Sendable {
    var pruneToolchainCache: @Sendable (KinhinConfig) async throws -> String
    var pruneImages: @Sendable (KinhinConfig, [VMRecord]) async throws -> String
    var startContainerSystem: @Sendable () async throws -> String
    var repairRuntime: @Sendable (RuntimeID) async throws -> String
    var repairTart: @Sendable (KinhinConfig) async throws -> String
    var tartHealth: @Sendable (KinhinConfig) async -> TartHealth
    var setupChecks: @Sendable (KinhinConfig) async -> [SetupCheckResult]

    init(
        pruneToolchainCache: @escaping @Sendable (KinhinConfig) async throws -> String,
        pruneImages: @escaping @Sendable (KinhinConfig, [VMRecord]) async throws -> String,
        startContainerSystem: @escaping @Sendable () async throws -> String,
        repairRuntime: @escaping @Sendable (RuntimeID) async throws -> String,
        repairTart: @escaping @Sendable (KinhinConfig) async throws -> String,
        tartHealth: @escaping @Sendable (KinhinConfig) async -> TartHealth,
        setupChecks: @escaping @Sendable (KinhinConfig) async -> [SetupCheckResult]
    ) {
        self.pruneToolchainCache = pruneToolchainCache
        self.pruneImages = pruneImages
        self.startContainerSystem = startContainerSystem
        self.repairRuntime = repairRuntime
        self.repairTart = repairTart
        self.tartHealth = tartHealth
        self.setupChecks = setupChecks
    }

    /// Does nothing outside the engine: every host fix fails with a clear
    /// message, tart reads healthy and there are no setup problems. The
    /// default for engines built without production wiring (tests).
    public static let inert = HealingHostActions(
        pruneToolchainCache: { _ in throw EngineError.healingFailed("host fixes are off in this engine") },
        pruneImages: { _, _ in throw EngineError.healingFailed("host fixes are off in this engine") },
        startContainerSystem: { throw EngineError.healingFailed("host fixes are off in this engine") },
        repairRuntime: { _ in throw EngineError.healingFailed("host fixes are off in this engine") },
        repairTart: { _ in throw EngineError.healingFailed("host fixes are off in this engine") },
        tartHealth: { _ in .healthy },
        setupChecks: { _ in [] })

    /// The real thing, through the same code paths as `kinhin image prune`,
    /// `kinhin toolchains prune` and `kinhin setup repair`.
    public static let live = HealingHostActions(
        pruneToolchainCache: { config in
            let policy = ToolchainCachePolicy(from: config.toolchainCache)
            let report = await Task.detached(priority: .utility) {
                ToolchainCachePruner().prune(policy: policy)
            }.value
            let megabytes = report.freedBytes / 1_048_576
            return "freed \(megabytes) MB from \(report.entries.count) cache entr(ies)"
        },
        pruneImages: { config, fleet in
            let inventory = await ImageInventory.probe(config: config)
            let plan = ImagePrunePlan.plan(inventory: inventory, config: config, fleet: fleet)
            guard !plan.isEmpty else { return "no unused images to prune" }
            let tart: (any TartControlling)?
            do {
                tart = try TartController(configuredPath: config.tartPath)
            } catch {
                // No tart: the tart targets fail on their own; the other runtimes still prune.
                Log.warn("healing", "tart unavailable for the image prune: \(error.localizedDescription)")
                tart = nil
            }
            try await plan.execute(
                tart: tart, container: AppleContainerRuntime(),
                docker: DockerRuntime(image: config.docker?.image ?? "kinhin-ci-linux"))
            let gigabytes = plan.reclaimGB.map { " (~\($0) GB)" } ?? ""
            return "pruned \(plan.targets.count) unused image(s) or stale record(s)\(gigabytes)"
        },
        startContainerSystem: {
            try await AppleContainerRuntime.startSystem()
            return "container system started"
        },
        repairRuntime: { runtime in
            if runtime == .host {
                let installer = HostAgentInstaller()
                guard !installer.isInstalled else { return "host runner agent already installed" }
                return "installed \(installer.installedSummary(try await installer.install()))"
            }
            let tool: InstallableTool
            switch runtime {
            case .tart: tool = .tart
            case .docker: tool = .docker
            case .appleContainer: tool = .appleContainer
            case .host: return "host runner agent already installed"
            }
            guard !tool.isInstalled else { return "\(tool.title) is already installed" }
            let option = try RuntimeInstaller.option(for: tool, method: nil, on: .current())
            try await RuntimeInstaller.install(option, tool: tool)
            return "installed \(tool.title) (\(option.title))"
        },
        repairTart: { config in
            let probe = TartHealthProbe(configuredPath: config.tartPath)
            guard let repair = TartHealthProbe.repairs(for: await probe.check()).first else {
                return "tart is healthy"
            }
            let shell = Shell()
            for command in repair.commands {
                guard let argv = RuntimeInstaller.resolve(command, brew: RuntimeInstaller.brewPath) else {
                    throw EngineError.healingFailed("\(command[0]) was not found")
                }
                let result = try await shell.run(argv, cwd: nil, timeout: 1800)
                guard result.succeeded else {
                    let output = result.stderr.isEmpty ? result.stdout : result.stderr
                    throw EngineError.healingFailed(
                        "\(command.joined(separator: " ")) failed: \(summarize(output))")
                }
            }
            return repair.title
        },
        tartHealth: { config in await TartHealthProbe(configuredPath: config.tartPath).check() },
        setupChecks: { config in await SetupStatusComputer(config: .loaded(config)).compute().checks })
}
