import Foundation

/// Computes the first-run prerequisite checklist. This is the single source of
/// truth consumed by both front ends (`kinhin setup-status` JSON and the menu
/// bar setup window), so they can never drift apart.
///
/// All probes are injectable: pass a non-nil value to substitute a fixture
/// (tests), or leave nil to probe the real machine (both front ends).
public struct SetupStatusComputer: Sendable {
    let host: HostResources?
    let clt: CLTState?
    let tartHealth: TartHealth?
    let tartList: [TartVM]?
    let config: ConfigScenario
    let tokenStored: Bool?
    let giteaTokenStored: Bool?
    /// Named-account token state by account name (fixture). nil probes the
    /// Keychain for each `accounts:` entry.
    let accountTokensStored: [String: Bool]?
    /// Keychain read failures by token key ("github", "gitea", "account:NAME"),
    /// reported by the caller that already probed. A failure renders as an
    /// error row instead of "token missing".
    let tokenReadFailures: [String: String]
    let containerHealth: RuntimeHealth?
    let containerImages: [String]?
    /// Whether the container Linux kernel is installed (fixture). nil probes
    /// the real host when the runtime health is probed live, and assumes
    /// installed when health is injected, so fixtures stay hermetic.
    let containerKernelInstalled: Bool?
    let dockerHealth: RuntimeHealth?
    let dockerImages: [String]?
    /// Architecture of the configured Docker image (fixture). nil probes the
    /// real image when `dockerImages` is not injected.
    let dockerImageArchitecture: String?
    /// Host-runtime agent health (fixture). nil probes the real agent dir.
    let hostHealth: RuntimeHealth?
    /// Shared toolchain cache state (fixture). nil probes the real host: the
    /// cache root's existence/writability, plus the config's `share_cache`.
    /// No live mount is probed — runners bind on demand.
    let toolchainCacheState: (usable: Bool, shareCacheOn: Bool)?
    /// macOS version runtime install options are judged against (fixture).
    /// nil reads the real version.
    let osVersion: OperatingSystemVersion?

    public init(
        host: HostResources? = nil,
        clt: CLTState? = nil,
        tartHealth: TartHealth? = nil,
        tartList: [TartVM]? = nil,
        config: ConfigScenario = .live,
        tokenStored: Bool? = nil,
        giteaTokenStored: Bool? = nil,
        accountTokensStored: [String: Bool]? = nil,
        tokenReadFailures: [String: String] = [:],
        containerHealth: RuntimeHealth? = nil,
        containerImages: [String]? = nil,
        containerKernelInstalled: Bool? = nil,
        dockerHealth: RuntimeHealth? = nil,
        dockerImages: [String]? = nil,
        dockerImageArchitecture: String? = nil,
        hostHealth: RuntimeHealth? = nil,
        toolchainCacheState: (usable: Bool, shareCacheOn: Bool)? = nil,
        osVersion: OperatingSystemVersion? = nil
    ) {
        self.host = host
        self.clt = clt
        self.tartHealth = tartHealth
        self.tartList = tartList
        self.config = config
        self.tokenStored = tokenStored
        self.giteaTokenStored = giteaTokenStored
        self.accountTokensStored = accountTokensStored
        self.tokenReadFailures = tokenReadFailures
        self.containerHealth = containerHealth
        self.containerImages = containerImages
        self.containerKernelInstalled = containerKernelInstalled
        self.dockerHealth = dockerHealth
        self.dockerImages = dockerImages
        self.dockerImageArchitecture = dockerImageArchitecture
        self.hostHealth = hostHealth
        self.toolchainCacheState = toolchainCacheState
        self.osVersion = osVersion
    }

    // MARK: - Token rows

    /// Precedence: a failure the caller already hit, then the fixture value,
    /// then a live Keychain read.
    private func tokenState(key: String, override: Bool?, read: () throws -> String?) -> TokenState {
        if let failure = tokenReadFailures[key] { return .unreadable(failure) }
        if let override { return override ? .stored : .missing }
        return TokenState(reading: read)
    }

    private func tokenRow(
        id: String, title: String, state: TokenState, missing: String, replaceAction: String, enterAction: String
    ) -> SetupCheckResult {
        switch state {
        case .stored:
            return SetupCheckResult(
                id: id, title: title, ok: true, detail: "stored in Keychain", action: replaceAction)
        case .missing:
            return SetupCheckResult(id: id, title: title, ok: false, detail: missing, action: enterAction)
        case .unreadable(let reason):
            // No fix button: re-entering a token the Keychain won't read back cannot help.
            return SetupCheckResult(
                id: id, title: title, ok: false,
                detail: "Keychain error — \(reason). Unlock the login keychain and try again.", action: nil)
        }
    }

    /// Loads the parsed config, or nil when missing/invalid.
    static func liveConfig() -> KinhinConfig? {
        guard FileManager.default.fileExists(atPath: Paths.config.path) else { return nil }
        do {
            return try ConfigLoader.load()
        } catch {
            // The checklist reports "invalid file"; the reason belongs in the log.
            Log.warn("setup", "config could not be loaded: \(error.localizedDescription)")
            return nil
        }
    }

    /// Resolves a config scenario to its fully-evaluated view — no filesystem
    /// access at evaluation time for non-live scenarios. Shared by the
    /// checklist and the doctor builder so both surfaces resolve the config
    /// identically and can never disagree.

    public func compute() async -> SetupStatus {
        // Resolve the config scenario once. Every branch below reads the
        // evaluation — never the real filesystem — so tests stay hermetic.
        let evaluation = Self.resolve(config)
        var parsed: KinhinConfig?
        if case .parsed(let cfg) = evaluation { parsed = cfg }

        let realHost = host ?? ResourceProbe().snapshot()
        let realCLT: CLTState
        if let clt {
            realCLT = clt
        } else {
            realCLT = await CLTProbe().check()
        }
        let health: TartHealth
        if let tartHealth {
            health = tartHealth
        } else {
            health = await TartHealthProbe(configuredPath: parsed?.tartPath).check()
        }

        let facts = HostFacts(
            resources: realHost, osVersion: osVersion ?? ProcessInfo.processInfo.operatingSystemVersion)
        var checks: [SetupCheckResult] = []

        // 1. Host
        checks.append(
            SetupCheckResult(
                id: "arch",
                title: "Apple Silicon Mac",
                ok: realHost.arm64,
                detail:
                    "\(realHost.logicalCores) cores · \(realHost.memoryGB) GB RAM · \(realHost.freeDiskGB) GB free disk",
                action: nil
            ))

        // 2. Command Line Tools — Homebrew can't build anything without them.
        // A mismatch here silently blocks the tart install, so it comes first.
        checks.append(
            SetupCheckResult(
                id: "clt",
                title: "Command Line Tools",
                ok: realCLT.isOK,
                detail: realCLT.detail,
                action: realCLT.isOK ? nil : "fix_clt"
            ))

        // 3. Tart (installed *and* launches)
        let tartHealthy = health == .healthy
        switch health {
        case .healthy:
            checks.append(
                SetupCheckResult(
                    id: "tart", title: "Tart installed", ok: true, detail: "installed and launches", action: nil))
        case .missing:
            checks.append(
                SetupCheckResult(
                    id: "tart", title: "Tart installed", ok: false,
                    detail: (parsed?.hasLinuxRuntime ?? false)
                        ? "not installed — only needed for macOS jobs" : "required to run macOS VMs",
                    action: "install_tart"))
        case .killedOnLaunch:
            checks.append(
                SetupCheckResult(
                    id: "tart-rollback",
                    title: "Tart is killed on launch",
                    ok: false,
                    detail:
                        "Gatekeeper blocked the un-notarized binary (openai/homebrew-tools#27) — roll back to the notarized Cirrus Labs build",
                    action: "rollback_tart"
                ))
        case .broken(let reason):
            checks.append(
                SetupCheckResult(
                    id: "tart", title: "Tart is not working", ok: false,
                    detail: "\(reason) — reinstall, or roll back to the Cirrus build", action: "reinstall_tart"))
        }

        // 4. Config — four states: working config, untouched template (the
        // placeholder repo must never earn a green checkmark), invalid file,
        // or none.
        checks.append(Self.configCheck(evaluation, path: Paths.config.path))

        // 4b. Provision script — only when the config declares one. A missing
        // or empty script hard-fails `image prepare` after its multi-GB
        // download, so the checklist catches it first, using the exact same
        // validation ImagePreparer applies (they cannot disagree).
        if case .parsed(let cfg) = evaluation, cfg.provisionScript != nil {
            checks.append(Self.provisionScriptCheck(cfg))
        }

        // 5. Token(s) — GitHub always (replaceable even when stored);
        // a Gitea row appears when the config declares that forge.
        // A Gitea-only config (no real GitHub repo) has no GitHub row.
        let githubInUse = parsed.map { $0.githubEnabled } ?? true
        if githubInUse {
            checks.append(
                tokenRow(
                    id: "token", title: "GitHub token stored",
                    state: tokenState(key: "github", override: tokenStored) { try KeychainTokenStore.load() },
                    missing: "a PAT with repo scope is required",
                    replaceAction: "replace_token", enterAction: "enter_token"))
        }
        if case .parsed(let cfg) = evaluation, cfg.gitea != nil {
            checks.append(
                tokenRow(
                    id: "gitea-token", title: "Gitea token stored",
                    state: tokenState(key: "gitea", override: giteaTokenStored) {
                        try KeychainTokenStore.load(forge: .gitea)
                    },
                    missing: "a Gitea access token with runner-management rights is required (kinhin auth set --gitea)",
                    replaceAction: "replace_gitea_token", enterAction: "enter_gitea_token"))
        }

        // One row per additional named account.
        if case .parsed(let cfg) = evaluation {
            for account in cfg.accounts {
                let provider = account.forge == .github ? "GitHub" : "Gitea"
                checks.append(
                    tokenRow(
                        id: "account-token-\(account.name)", title: "\(provider) token stored (\(account.name))",
                        state: tokenState(key: "account:\(account.name)", override: accountTokensStored?[account.name])
                        {
                            try KeychainTokenStore.load(forge: account.forge, name: account.name)
                        },
                        missing: "a token for \(account.scope) is required (kinhin auth set --account \(account.name))",
                        replaceAction: "replace_account_token", enterAction: "enter_account_token"))
            }
        }

        // 6. Runner image
        var imageOK = false
        var imageDetail = "run after tart is installed"
        if !tartHealthy {
            imageDetail = health == .missing ? "run after tart is installed" : "could not launch tart"
        } else if let cfg = parsed {
            let images: [TartVM]?
            if let tartList {
                images = tartList
            } else if let controller = try? TartController(configuredPath: cfg.tartPath) {
                images = try? await controller.list()
            } else {
                images = nil
            }
            if let images {
                imageOK = images.contains { $0.name == cfg.image || $0.source == cfg.image }
                imageDetail = imageOK ? "image '\(cfg.image)' found" : "image '\(cfg.image)' not local yet"
            } else {
                imageDetail = "could not launch tart"
            }
        }
        checks.append(
            SetupCheckResult(
                id: "image",
                title: "Runner image prepared",
                ok: imageOK,
                detail: imageDetail,
                action: imageOK ? nil : "prepare_image"
            ))

        // 7. Apple-container runtime — rows appear only when the config
        // enables the container runtime, mirroring the gitea-token row.
        if case .parsed(let cfg) = evaluation, cfg.container != nil {
            let resolvedHealth: RuntimeHealth
            if let containerHealth {
                resolvedHealth = containerHealth
            } else {
                resolvedHealth = await AppleContainerRuntime().health()
            }
            switch resolvedHealth {
            case .ready:
                checks.append(
                    SetupCheckResult(
                        id: "container-cli",
                        title: "Apple container",
                        ok: true,
                        detail: "installed and the container system is running",
                        action: nil
                    ))
            case .missing:
                // No install button when it can't run here: say why instead.
                let blocked = HostRequirements.blockingReason(for: .appleContainer, on: facts)
                checks.append(
                    SetupCheckResult(
                        id: "container-cli",
                        title: "Apple container",
                        ok: false,
                        detail: blocked ?? "the container CLI is required for Linux container runners",
                        action: blocked == nil ? "install_container_cli" : nil
                    ))
            case .broken(let why):
                checks.append(
                    SetupCheckResult(
                        id: "container-cli",
                        title: "Apple container",
                        ok: false,
                        detail: why,
                        action: "start_container_system"
                    ))
            default:
                break
            }

            // Only surfaced when missing: the container system can be running
            // without a Linux kernel, and then no container can start.
            if resolvedHealth.isReady {
                let kernelInstalled =
                    containerKernelInstalled
                    ?? (containerHealth == nil ? AppleContainerRuntime.hasInstalledKernel() : true)
                if !kernelInstalled {
                    checks.append(
                        SetupCheckResult(
                            id: "container-kernel",
                            title: "Container Linux kernel",
                            ok: false,
                            detail: "not installed — Linux containers can't start without it (a one-time download)",
                            action: "install_container_kernel"
                        ))
                }
            }

            let wanted = cfg.container?.image ?? "kinhin-ci-linux"
            let listed: [String]
            if let containerImages {
                listed = containerImages
            } else if resolvedHealth.isReady {
                listed = await AppleContainerRuntime().localImageNames()
            } else {
                listed = []
            }
            let imageFound = listed.contains { $0 == wanted || $0.hasPrefix("\(wanted):") }
            checks.append(
                SetupCheckResult(
                    id: "container-image",
                    title: "Container image prepared",
                    ok: imageFound,
                    detail: !resolvedHealth.isReady
                        ? "run after the container system is running"
                        : (imageFound ? "image '\(wanted)' found" : "image '\(wanted)' not local yet"),
                    action: imageFound ? nil : "prepare_container_image"
                ))
        }

        // 8. Docker runtime — rows appear only when the config declares a
        // `docker:` section, mirroring the container rows above.
        if case .parsed(let cfg) = evaluation, cfg.docker != nil {
            let docker = DockerRuntime(image: cfg.docker?.image ?? "kinhin-ci-linux")
            let resolvedHealth: RuntimeHealth
            if let dockerHealth {
                resolvedHealth = dockerHealth
            } else {
                resolvedHealth = await docker.health()
            }
            switch resolvedHealth {
            case .ready:
                checks.append(
                    SetupCheckResult(
                        id: "docker-cli",
                        title: "Docker",
                        ok: true,
                        detail: "installed and the Docker daemon is reachable",
                        action: nil
                    ))
            case .missing:
                let blocked = HostRequirements.blockingReason(for: .docker, on: facts)
                checks.append(
                    SetupCheckResult(
                        id: "docker-cli",
                        title: "Docker",
                        ok: false,
                        detail: blocked
                            ?? "the docker CLI is required for Linux container runners (Docker Desktop, OrbStack, or colima)",
                        action: blocked == nil ? "install_docker" : nil
                    ))
            case .broken(let why):
                checks.append(
                    SetupCheckResult(
                        id: "docker-cli",
                        title: "Docker",
                        ok: false,
                        detail: why,
                        action: nil
                    ))
            }

            let wanted = cfg.docker?.image ?? "kinhin-ci-linux"
            let listed: [String]
            if let dockerImages {
                listed = dockerImages
            } else if resolvedHealth.isReady {
                listed = await docker.localImageNames()
            } else {
                listed = []
            }
            let imageFound = listed.contains { $0 == wanted || $0.hasPrefix("\(wanted):") }
            // The image must match docker.platform: a stale arm64 image under
            // a linux/amd64 config (or the reverse) would run the wrong agent.
            let platform = cfg.docker?.platform ?? .arm64
            var imageArch = dockerImageArchitecture
            if imageArch == nil, dockerImages == nil, imageFound {
                imageArch = await docker.imageArchitecture(of: wanted)
            }
            let archMismatch = imageFound && (imageArch.map { $0 != platform.dockerArchitecture } ?? false)
            var detail =
                !resolvedHealth.isReady
                ? "run after the Docker daemon is reachable"
                : (imageFound ? "image '\(wanted)' found" : "image '\(wanted)' not local yet")
            if archMismatch, let imageArch {
                detail =
                    "image '\(wanted)' is \(imageArch) but docker.platform is \(platform.rawValue) — run image prepare"
            }
            if platform.isEmulated { detail += " · \(LinuxPlatform.emulationNotice)" }
            checks.append(
                SetupCheckResult(
                    id: "docker-image",
                    title: "Docker image prepared",
                    ok: imageFound && !archMismatch,
                    detail: detail,
                    action: (imageFound && !archMismatch) ? nil : "prepare_docker_image"
                ))
        }

        // 8b. Host runtime — the row appears only when a route targets
        // `host`. The agent must be installed, and the detail keeps the
        // "unisolated" disclosure in front of the user.
        if case .parsed(let cfg) = evaluation, cfg.hostRoutesConfigured {
            let resolvedHealth: RuntimeHealth
            if let hostHealth {
                resolvedHealth = hostHealth
            } else {
                resolvedHealth = await HostRuntime().health()
            }
            switch resolvedHealth {
            case .ready:
                checks.append(
                    SetupCheckResult(
                        id: "host-agent",
                        title: "Host runner agent",
                        ok: true,
                        detail: "installed — host routes run repo code directly on this Mac, unisolated",
                        action: nil
                    ))
            case .missing:
                checks.append(
                    SetupCheckResult(
                        id: "host-agent",
                        title: "Host runner agent",
                        ok: false,
                        detail:
                            "the GitHub and Gitea runner agents aren't installed (host routes run directly on this Mac)",
                        action: "install_host_agent"
                    ))
            case .broken(let why):
                checks.append(
                    SetupCheckResult(id: "host-agent", title: "Host runner agent", ok: false, detail: why, action: nil))
            }
        }

        // 9. Shared toolchain cache — advisory row for the host cache that
        // prepare writes through and runners bind when share_cache is on.
        // It never blocks readiness (the cache is regenerable by design;
        // every consumer recreates or skips it gracefully).
        if let cacheState = toolchainCacheState {
            checks.append(Self.toolchainCacheCheck(usable: cacheState.usable, shareCacheOn: cacheState.shareCacheOn))
        } else {
            let fm = FileManager.default
            var isDir: ObjCBool = false
            let exists = fm.fileExists(atPath: Paths.toolchainCache.path, isDirectory: &isDir)
            let usable = exists && isDir.boolValue && fm.isWritableFile(atPath: Paths.toolchainCache.path)
            let shareCacheOn = parsed?.toolchains?.shareCache ?? false
            checks.append(Self.toolchainCacheCheck(usable: usable, shareCacheOn: shareCacheOn))
        }

        // Linux-only: tart isn't installed but a Linux runtime is configured, so
        // the macOS-only rows (Command Line Tools, tart, base image) don't
        // gate readiness — they only matter for macOS jobs.
        let linuxOnly = health == .missing && (parsed?.hasLinuxRuntime ?? false)
        let macOnlyIDs: Set<String> = ["clt", "tart", "image"]
        let gating = checks.filter { !(linuxOnly && macOnlyIDs.contains($0.id)) }
        return SetupStatus(ready: gating.allSatisfy(\.ok), checks: checks)
    }

    /// The shared toolchain cache row: green when usable (or when it simply
    /// isn't needed yet), red-but-advisory only when `share_cache` is on and
    /// the host directory is missing/unwritable — that combination would
    /// leave every runner's cache mounts silently empty.
    static func toolchainCacheCheck(usable: Bool, shareCacheOn: Bool) -> SetupCheckResult {
        if usable {
            return SetupCheckResult(
                id: "toolchain-cache",
                title: "Shared toolchain cache",
                ok: true,
                detail: shareCacheOn
                    ? "host cache ready — runner VMs and containers mount it (share_cache on)"
                    : "host cache ready — `share_cache: true` also mounts it into runners",
                action: nil
            )
        }
        return SetupCheckResult(
            id: "toolchain-cache",
            title: "Shared toolchain cache",
            ok: true,  // advisory: a missing cache never blocks onboarding
            detail: shareCacheOn
                ? "host cache directory missing — runner mounts will be empty until the next prepare recreates it"
                : "not created yet — the next `kinhin image prepare` creates it",
            action: shareCacheOn ? "create_toolchain_cache" : nil
        )
    }

    /// The provision-script row: green when the configured script exists and
    /// is non-empty — exactly what `image prepare` will validate — otherwise
    /// a fix row pointing at config.yaml. Only called for configs that
    /// declare `provision_script`.
    static func provisionScriptCheck(_ cfg: KinhinConfig) -> SetupCheckResult {
        func broken(_ detail: String) -> SetupCheckResult {
            SetupCheckResult(
                id: "provision-script",
                title: "Provision script",
                ok: false,
                detail: detail,
                action: "repair_provision_script"
            )
        }
        do {
            let resolved = try ImagePreparer.resolveProvisionScript(cfg.provisionScript)
            return SetupCheckResult(
                id: "provision-script",
                title: "Provision script",
                ok: true,
                detail: "script found: \(resolved?.path ?? "")",
                action: nil
            )
        } catch let error as ImageError {
            guard case .provisionScriptUnreadable(let path, let reason) = error else {
                return broken("\(cfg.provisionScript ?? "") (unusable)")
            }
            if reason == "script is empty" {
                return broken("\(path) is empty — add commands or remove provision_script from config.yaml")
            }
            return broken("missing or unreadable at \(path) — fix the path in config.yaml")
        } catch {
            return broken("\(cfg.provisionScript ?? "") (unusable: \(error))")
        }
    }

    /// The full config row, total over every evaluation state: working config
    /// (ok), untouched template (created — needs your repo, Edit Config),
    /// invalid file, or missing (Create Config).
    static func configCheck(_ evaluation: ConfigEvaluation, path: String) -> SetupCheckResult {
        switch evaluation {
        case .parsed(let cfg):
            var scope = cfg.repo.contains("/") ? "repo: \(cfg.repo)" : "org: \(cfg.repo) (all its repos)"
            if !cfg.githubEnabled, let gitea = cfg.gitea {
                scope = "gitea: \(gitea.scope) @ \(gitea.instance)"
            } else if !cfg.githubEnabled {
                scope = "accounts: \(cfg.accounts.map(\.name).joined(separator: ", "))"
            }
            if cfg.githubEnabled || cfg.gitea != nil, !cfg.accounts.isEmpty {
                scope += " + \(cfg.accounts.count) more account\(cfg.accounts.count == 1 ? "" : "s")"
            }
            return SetupCheckResult(
                id: "config",
                title: "Config created",
                ok: true,
                detail: "\(scope) · labels: \(cfg.labels.joined(separator: ","))",
                action: nil
            )
        case .templateConfig:
            return SetupCheckResult(
                id: "config",
                title: "Config created",
                ok: false,
                detail: "template created — set your repo in \(path)",
                action: "edit_config"
            )
        case .invalidFile:
            return SetupCheckResult(
                id: "config",
                title: "Config created",
                ok: false,
                detail: "\(path) (invalid)",
                action: "create_config"
            )
        case .noFile:
            return SetupCheckResult(
                id: "config",
                title: "Config created",
                ok: false,
                detail: "not created yet",
                action: "create_config"
            )
        }
    }

    /// Scenario → evaluation. `.live` probes the real filesystem (and
    /// classifies a parsed file as template vs working); every other case
    /// maps directly to its evaluation.
    static func resolve(_ config: ConfigScenario) -> ConfigEvaluation {
        switch config {
        case .live:
            if let cfg = liveConfig() {
                return ConfigLoader.hasAnyForge(cfg) ? .parsed(cfg) : .templateConfig
            }
            return FileManager.default.fileExists(atPath: Paths.config.path) ? .invalidFile : .noFile
        case .missing:
            return .noFile
        case .invalid:
            return .invalidFile
        case .template:
            return .templateConfig
        case .loaded(let cfg):
            return ConfigLoader.hasAnyForge(cfg) ? .parsed(cfg) : .templateConfig
        }
    }
}
