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

        // 5. Token(s) — one row per configured account, in config order. The
        // legacy per-forge rows are gone: every forge is an accounts: entry.
        // A template config (no accounts) has no token rows.
        if case .parsed(let cfg) = evaluation {
            for account in cfg.accounts {
                let provider = account.forge.displayName
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
        var localTartVMs: [TartVM] = []
        if !tartHealthy {
            imageDetail = health == .missing ? "run after tart is installed" : "could not launch tart"
        } else if let cfg = parsed {
            let images: [TartVM]?
            var listFailure: String?
            if let tartList {
                images = tartList
            } else {
                do {
                    images = try await TartController(configuredPath: cfg.tartPath).list()
                } catch {
                    listFailure = error.localizedDescription
                    Log.warn("setup", "could not list tart images: \(error.localizedDescription)")
                    images = nil
                }
            }
            if let images {
                localTartVMs = images
                imageOK = images.contains { $0.name == cfg.image || $0.source == cfg.image }
                imageDetail = imageOK ? "image '\(cfg.image)' found" : "image '\(cfg.image)' not local yet"
            } else {
                imageDetail = listFailure.map { "could not list tart images: \($0)" } ?? "could not launch tart"
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

        // 6b. Base image — only when the config sets the top-level
        // `base_image:`. Advisory: an unknown reference leaves today's fleet
        // untouched and only fails the next prepare (after the pull), so the
        // row explains the fix instead of blocking onboarding. Reuses the
        // tart list the image row just fetched — no second probe.
        if case .parsed(let cfg) = evaluation, cfg.baseImage != nil {
            checks.append(Self.baseImageCheck(cfg: cfg, localVMs: localTartVMs))
        }

        // 7. Apple-container runtime — rows appear only when the config
        // enables the container runtime, mirroring the gitea-token row.
        if case .parsed(let cfg) = evaluation, cfg.container != nil {
            checks += await containerChecks(cfg, facts: facts)
        }

        // 8. Docker runtime — rows appear only when the config declares a
        // `docker:` section, mirroring the container rows above.
        if case .parsed(let cfg) = evaluation, cfg.docker != nil {
            checks += await dockerChecks(cfg, facts: facts)
        }

        // 8b. Host runtime — the row appears only when a route targets
        // `host`. The agent must be installed, and the detail keeps the
        // "unisolated" disclosure in front of the user.
        if case .parsed(let cfg) = evaluation, cfg.hostRoutesConfigured {
            checks += await hostAgentChecks()
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
        let macOnlyIDs: Set<String> = ["clt", "tart", "image", "base-image"]
        let gating = checks.filter { !(linuxOnly && macOnlyIDs.contains($0.id)) }
        return SetupStatus(ready: gating.allSatisfy(\.ok), checks: checks)
    }
}
