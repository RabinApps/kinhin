import Foundation

/// Builds the merged DoctorReport. Every probe is injectable: pass a fixture
/// to substitute it (tests), or leave nil to probe the real machine (the CLI).
/// The checklist half is delegated to `SetupStatusComputer` and the auth half
/// to `AuthStatusReporter`, so the JSON document can never drift from the
/// human surfaces it mirrors.
public struct DoctorReportBuilder: Sendable {
    let host: HostResources?
    let clt: CLTState?
    let tartHealth: TartHealth?
    let tartList: [TartVM]?
    let config: ConfigScenario
    /// Stands in for the Keychain (`.live` passes `KeychainTokenStore.load`).
    let authLoad: @Sendable (ForgeID) throws -> String?
    /// Same, for the named `accounts:` entries.
    let accountLoad: @Sendable (ForgeID, String) throws -> String?
    let containerHealth: RuntimeHealth?
    let containerImages: [String]?
    let dockerHealth: RuntimeHealth?
    let dockerImages: [String]?
    let hostHealth: RuntimeHealth?
    /// Whether the docker CLI is installed (fixture). nil infers it from an
    /// injected `dockerHealth`, else looks it up on PATH.
    let dockerInstalled: Bool?
    /// macOS version the host requirements are judged against (fixture).
    let osVersion: OperatingSystemVersion?

    public init(
        host: HostResources? = nil,
        clt: CLTState? = nil,
        tartHealth: TartHealth? = nil,
        tartList: [TartVM]? = nil,
        config: ConfigScenario = .live,
        authLoad: @escaping @Sendable (ForgeID) throws -> String? = { try KeychainTokenStore.load(forge: $0) },
        accountLoad: @escaping @Sendable (ForgeID, String) throws -> String? = {
            try KeychainTokenStore.load(forge: $0, name: $1)
        },
        containerHealth: RuntimeHealth? = nil,
        containerImages: [String]? = nil,
        dockerHealth: RuntimeHealth? = nil,
        dockerImages: [String]? = nil,
        hostHealth: RuntimeHealth? = nil,
        dockerInstalled: Bool? = nil,
        osVersion: OperatingSystemVersion? = nil
    ) {
        self.host = host
        self.clt = clt
        self.tartHealth = tartHealth
        self.tartList = tartList
        self.config = config
        self.authLoad = authLoad
        self.accountLoad = accountLoad
        self.containerHealth = containerHealth
        self.containerImages = containerImages
        self.dockerHealth = dockerHealth
        self.dockerImages = dockerImages
        self.hostHealth = hostHealth
        self.dockerInstalled = dockerInstalled
        self.osVersion = osVersion
    }

    public func build() async -> DoctorReport {
        let resolvedHost = host ?? ResourceProbe().snapshot()
        let resolvedCLT: CLTState
        if let clt {
            resolvedCLT = clt
        } else {
            resolvedCLT = await CLTProbe().check()
        }

        // The tart probe must honor the config's tart_path override, exactly
        // like the checklist does — the scenario is resolved through the same
        // shared code, so doctor and checklist can never disagree.
        let evaluation = SetupStatusComputer.resolve(config)
        var parsed: KinhinConfig?
        if case .parsed(let cfg) = evaluation { parsed = cfg }
        let resolvedTart: TartHealth
        if let tartHealth {
            resolvedTart = tartHealth
        } else {
            resolvedTart = await TartHealthProbe(configuredPath: parsed?.tartPath).check()
        }

        // The checklist sees the same token source as the auth report — one
        // source of truth (live → real Keychain, tests → fixture). A read that
        // fails is recorded so the checklist shows the error, not "missing".
        var tokenFailures: [String: String] = [:]
        func stored(_ key: String, _ read: () throws -> String?) -> Bool {
            do {
                return try read() != nil
            } catch {
                tokenFailures[key] = error.localizedDescription
                return false
            }
        }
        let githubStored = stored("github") { try authLoad(.github) }
        let giteaStored = stored("gitea") { try authLoad(.gitea) }
        var accountStored: [String: Bool] = [:]
        for account in parsed?.accounts ?? [] {
            accountStored[account.name] = stored("account:\(account.name)") {
                try accountLoad(account.forge, account.name)
            }
        }
        let status = await SetupStatusComputer(
            host: resolvedHost,
            clt: resolvedCLT,
            tartHealth: resolvedTart,
            tartList: tartList,
            config: config,
            tokenStored: githubStored,
            giteaTokenStored: giteaStored,
            accountTokensStored: accountStored,
            tokenReadFailures: tokenFailures,
            containerHealth: containerHealth,
            containerImages: containerImages,
            dockerHealth: dockerHealth,
            dockerImages: dockerImages,
            hostHealth: hostHealth
        ).compute()

        let authReport = AuthStatusReporter.report(config: parsed, load: authLoad, loadAccount: accountLoad)

        // Apple-container section — present only when the config enables it,
        // with the same image-matching rule the checklist row uses.
        var containerSection: DoctorReport.ContainerSection?
        if let container = parsed?.container {
            let resolvedHealth: RuntimeHealth
            if let containerHealth {
                resolvedHealth = containerHealth
            } else {
                resolvedHealth = await AppleContainerRuntime().health()
            }
            let state: String
            let ok: Bool
            var fix: String?
            switch resolvedHealth {
            case .ready:
                state = "ready"; ok = true; fix = nil
            case .missing(_, let howToFix):
                state = "missing"; ok = false; fix = howToFix
            case .broken(let why):
                state = "broken"; ok = false; fix = why
            }
            let wanted = container.image
            let listed: [String]
            if let containerImages {
                listed = containerImages
            } else if resolvedHealth.isReady {
                listed = await AppleContainerRuntime().localImageNames()
            } else {
                listed = []
            }
            let imageFound = listed.contains { $0 == wanted || $0.hasPrefix("\(wanted):") }
            // A working runtime with a missing image gets the prepare command
            // — the same advice the human doctor prints for that case.
            if ok, !imageFound {
                fix = "kinhin image prepare --container --target \(wanted)"
            }
            containerSection = DoctorReport.ContainerSection(
                state: state, ok: ok, fix: fix, image: wanted, imageFound: imageFound
            )
        }

        // Docker section — same presence rule, health mapping, image matching,
        // and prepare-command advice as the container section above.
        var dockerSection: DoctorReport.DockerSection?
        if let docker = parsed?.docker {
            let runtime = DockerRuntime(image: docker.image)
            let resolvedHealth: RuntimeHealth
            if let dockerHealth {
                resolvedHealth = dockerHealth
            } else {
                resolvedHealth = await runtime.health()
            }
            let state: String
            let ok: Bool
            var fix: String?
            switch resolvedHealth {
            case .ready:
                state = "ready"; ok = true; fix = nil
            case .missing(_, let howToFix):
                state = "missing"; ok = false; fix = howToFix
            case .broken(let why):
                state = "broken"; ok = false; fix = why
            }
            let wanted = docker.image
            let listed: [String]
            if let dockerImages {
                listed = dockerImages
            } else if resolvedHealth.isReady {
                listed = await runtime.localImageNames()
            } else {
                listed = []
            }
            let imageFound = listed.contains { $0 == wanted || $0.hasPrefix("\(wanted):") }
            var imageArch: String?
            if imageFound, dockerImages == nil, resolvedHealth.isReady {
                imageArch = await runtime.imageArchitecture(of: wanted)
            }
            let archMismatch = imageFound && (imageArch.map { $0 != docker.platform.dockerArchitecture } ?? false)
            if ok, !imageFound {
                fix = "kinhin image prepare --docker --target \(wanted)"
            } else if ok, archMismatch, let imageArch {
                fix =
                    "image is \(imageArch) but docker.platform is \(docker.platform.rawValue): kinhin image prepare --docker --target \(wanted)"
            }
            dockerSection = DoctorReport.DockerSection(
                state: state, ok: ok, fix: fix, image: wanted, imageFound: imageFound,
                platform: docker.platform.rawValue, imageArchitecture: imageArch,
                note: docker.platform.isEmulated ? LinuxPlatform.emulationNotice : nil
            )
        }

        // Docker availability — always reported, so Diagnostics can say
        // whether Docker is installed and supported before it's enabled.
        let facts = HostFacts(
            resources: resolvedHost, osVersion: osVersion ?? ProcessInfo.processInfo.operatingSystemVersion)
        let dockerBlocked = HostRequirements.blockingReason(for: .docker, on: facts)
        let dockerFound: Bool
        if let dockerInstalled {
            dockerFound = dockerInstalled
        } else if let dockerHealth {
            if case .missing = dockerHealth { dockerFound = false } else { dockerFound = true }
        } else {
            dockerFound = InstallableTool.docker.isInstalled
        }
        let dockerAvailability = DoctorReport.DockerAvailabilitySection(
            installed: dockerFound, supported: dockerBlocked == nil, reason: dockerBlocked)

        // Host section — present only when a route targets `host`; the
        // unisolated warning is always attached.
        var hostSection: DoctorReport.HostSection?
        if let parsed, parsed.hostRoutesConfigured {
            let resolvedHealth: RuntimeHealth
            if let hostHealth {
                resolvedHealth = hostHealth
            } else {
                resolvedHealth = await HostRuntime().health()
            }
            let state: String
            let ok: Bool
            var fix: String?
            switch resolvedHealth {
            case .ready:
                state = "ready"; ok = true; fix = nil
            case .missing:
                state = "missing"; ok = false; fix = "kinhin setup repair host-agent"
            case .broken(let why):
                state = "broken"; ok = false; fix = why
            }
            hostSection = DoctorReport.HostSection(
                state: state, ok: ok, fix: fix,
                routes: (parsed.runtimes?.routes ?? []).filter { $0.runtime == RuntimeID.host.rawValue }.map(\.pattern),
                warning: "host routes run repo code directly on this Mac with your privileges, unisolated"
            )
        }

        // Shared toolchain cache — directory state only (no live mounts
        // probed; runners mount on demand). The per-ecosystem breakdown
        // covers the subdirectories the config's toolchains selection uses,
        // falling back to all top-level directories with content.
        let cacheSection = Self.toolchainCacheSection(config: parsed)

        // Capacity — the same math the human doctor prints, plus job slots.
        // The disk estimate matches the engine's scaler (explicit disk_gb or
        // the runtime default), so doctor's cap is the cap the fleet enforces.
        var capacitySection: DoctorReport.CapacitySection?
        if let cfg = parsed {
            let runtimeID =
                cfg.container != nil
                ? RuntimeID.appleContainer.rawValue
                : cfg.docker != nil ? RuntimeID.docker.rawValue : RuntimeID.tart.rawValue
            let plan = Capacity.plan(
                host: resolvedHost,
                vmCPU: cfg.vm.cpuCount,
                vmMemoryGB: cfg.vm.memoryGB,
                reservedCPU: cfg.reserve.cpu,
                reservedMemoryGB: cfg.reserve.memoryGB,
                diskPerVMGB: ResourceProbe.effectiveDiskPerVMGB(diskGB: cfg.diskGB, runtime: runtimeID),
                userMax: cfg.maxRunners
            )
            capacitySection = DoctorReport.CapacitySection(
                maxConcurrent: plan.maxConcurrent,
                bindingConstraint: plan.bindingConstraint,
                fits: plan.fits,
                jobSlots: plan.maxConcurrent * max(1, cfg.runnersPerVM)
            )
        }

        return DoctorReport(
            host: resolvedHost,
            clt: Self.cltSection(from: resolvedCLT),
            tart: Self.tartSection(from: resolvedTart),
            container: containerSection,
            docker: dockerSection,
            dockerAvailability: dockerAvailability,
            hostRuntime: hostSection,
            toolchainCache: cacheSection,
            auth: authReport,
            checks: status.checks,
            ready: status.ready && authReport.allGood,
            capacity: capacitySection
        )
    }
}
