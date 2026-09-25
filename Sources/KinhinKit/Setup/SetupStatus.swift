import Foundation

/// One prerequisite row of the first-run checklist. The JSON contract shared
/// by `kinhin setup-status` and the menu bar setup window — treat field
/// values (especially `id` and `action`) as a stable API.
public struct SetupCheckResult: Codable, Equatable, Sendable {
    /// Stable identifier: arch, tart, tart-rollback, config, token, image.
    public let id: String
    public let title: String
    public let ok: Bool
    /// Human-readable status line (contains no secrets).
    public let detail: String
    /// Stable action identifier for the fix button, or nil when nothing to do.
    public let action: String?

    public init(id: String, title: String, ok: Bool, detail: String, action: String?) {
        self.id = id
        self.title = title
        self.ok = ok
        self.detail = detail
        self.action = action
    }
}

/// The whole checklist plus whether onboarding is complete.
public struct SetupStatus: Codable, Equatable, Sendable {
    public let ready: Bool
    public let checks: [SetupCheckResult]

    public init(ready: Bool, checks: [SetupCheckResult]) {
        self.ready = ready
        self.checks = checks
    }
}

/// Human-readable labels for the stable action identifiers — shared so the
/// CLI and the app render the same fix-button text.
public enum SetupAction {
    public static func title(for action: String) -> String {
        switch action {
        case "fix_clt": return "Reinstall Command Line Tools"
        case "install_tart": return "Install via Homebrew"
        case "rollback_tart": return "Roll Back to Cirrus Build"
        case "reinstall_tart": return "Reinstall via Homebrew"
        case "create_config": return "Create Config"
        case "edit_config": return "Edit Config"
        case "enter_token": return "Enter Token…"
        case "replace_token": return "Replace Token…"
        case "enter_gitea_token": return "Enter Gitea Token…"
        case "replace_gitea_token": return "Replace Gitea Token…"
        case "install_container_cli": return "Install Apple container"
        case "start_container_system": return "Start container system"
        case "prepare_container_image": return "Prepare Container Image"
        case "prepare_docker_image": return "Prepare Docker Image"
        case "prepare_image": return "Prepare Image"
        case "repair_provision_script": return "Fix Provision Script…"
        case "create_toolchain_cache": return "Create Toolchain Cache"
        default: return action
        }
    }
}

/// Which config the checklist should see. `.live` probes the real machine;
/// every other case is a hermetic fixture for tests (and for callers that
/// already know the state). Replaces the old partial `configMissing` override.
public enum ConfigScenario: Sendable {
    /// Probe the real filesystem (front ends).
    case live
    /// Fresh machine: no config file.
    case missing
    /// File exists but does not parse/validate.
    case invalid
    /// Untouched starter template (placeholder repo).
    case template
    /// A caller-supplied parsed config (template-ness is detected from its repo).
    case loaded(KinhinConfig)
}

/// Internal, fully-resolved view of the scenario — no filesystem at evaluation time.
enum ConfigEvaluation {
    case parsed(KinhinConfig)
    case templateConfig
    case invalidFile
    case noFile
}

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
    let containerHealth: RuntimeHealth?
    let containerImages: [String]?
    let dockerHealth: RuntimeHealth?
    let dockerImages: [String]?
    /// Shared toolchain cache state (fixture). nil probes the real host: the
    /// cache root's existence/writability, plus the config's `share_cache`.
    /// No live mount is probed — runners bind on demand.
    let toolchainCacheState: (usable: Bool, shareCacheOn: Bool)?

    public init(
        host: HostResources? = nil,
        clt: CLTState? = nil,
        tartHealth: TartHealth? = nil,
        tartList: [TartVM]? = nil,
        config: ConfigScenario = .live,
        tokenStored: Bool? = nil,
        giteaTokenStored: Bool? = nil,
        containerHealth: RuntimeHealth? = nil,
        containerImages: [String]? = nil,
        dockerHealth: RuntimeHealth? = nil,
        dockerImages: [String]? = nil,
        toolchainCacheState: (usable: Bool, shareCacheOn: Bool)? = nil
    ) {
        self.host = host
        self.clt = clt
        self.tartHealth = tartHealth
        self.tartList = tartList
        self.config = config
        self.tokenStored = tokenStored
        self.giteaTokenStored = giteaTokenStored
        self.containerHealth = containerHealth
        self.containerImages = containerImages
        self.dockerHealth = dockerHealth
        self.dockerImages = dockerImages
        self.toolchainCacheState = toolchainCacheState
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
        let realToken = tokenStored ?? (KeychainTokenStore.load() != nil)
        let health: TartHealth
        if let tartHealth {
            health = tartHealth
        } else {
            health = await TartHealthProbe(configuredPath: parsed?.tartPath).check()
        }

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
                SetupCheckResult(
                    id: "token",
                    title: "GitHub token stored",
                    ok: realToken,
                    detail: realToken ? "stored in Keychain" : "a PAT with repo scope is required",
                    action: realToken ? "replace_token" : "enter_token"
                ))
        }
        if case .parsed(let cfg) = evaluation, cfg.gitea != nil {
            let giteaToken = giteaTokenStored ?? (KeychainTokenStore.load(forge: .gitea) != nil)
            checks.append(
                SetupCheckResult(
                    id: "gitea-token",
                    title: "Gitea token stored",
                    ok: giteaToken,
                    detail: giteaToken
                        ? "stored in Keychain"
                        : "a Gitea access token with runner-management rights is required (kinhin auth set --gitea)",
                    action: giteaToken ? "replace_gitea_token" : "enter_gitea_token"
                ))
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
                checks.append(
                    SetupCheckResult(
                        id: "container-cli",
                        title: "Apple container",
                        ok: false,
                        detail: "the container CLI is required for Linux container runners",
                        action: "install_container_cli"
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
                checks.append(
                    SetupCheckResult(
                        id: "docker-cli",
                        title: "Docker",
                        ok: false,
                        detail:
                            "the docker CLI is required for Linux container runners (Docker Desktop, OrbStack, or colima)",
                        action: "install_container_cli"
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
            checks.append(
                SetupCheckResult(
                    id: "docker-image",
                    title: "Docker image prepared",
                    ok: imageFound,
                    detail: !resolvedHealth.isReady
                        ? "run after the Docker daemon is reachable"
                        : (imageFound ? "image '\(wanted)' found" : "image '\(wanted)' not local yet"),
                    action: imageFound ? nil : "prepare_docker_image"
                ))
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
