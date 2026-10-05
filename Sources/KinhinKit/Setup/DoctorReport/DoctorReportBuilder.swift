import Foundation
import Synchronization

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
    /// Whether the `softnet` binary is installed (fixture). nil looks it up on PATH.
    let softnetInstalled: Bool?
    /// Where the daemon records an unpinned guest SSH host key (tests point it elsewhere).
    let hostKeyMarker: URL?
    /// The active org-permission check (mints and discards a registration
    /// token): takes the stored token and the org scope, returns the verdict
    /// line. Only the human rendering runs it; tests substitute a fixture.
    let orgPermissionCheck: @Sendable (String, String, String?) async -> String

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
        osVersion: OperatingSystemVersion? = nil,
        softnetInstalled: Bool? = nil,
        hostKeyMarker: URL? = nil,
        orgPermissionCheck: @escaping @Sendable (String, String, String?) async -> String = { token, scope, instance in
            await TokenHealthCheck.github(token: token, scope: scope, instance: instance).message
        }
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
        self.softnetInstalled = softnetInstalled
        self.hostKeyMarker = hostKeyMarker
        self.orgPermissionCheck = orgPermissionCheck
    }

    /// Memoizes a Keychain read so the checklist and the auth report share one
    /// read per token (a Keychain read can prompt and is not free).
    private final class TokenReads: Sendable {
        private let cache = Mutex<[String: Result<String?, Error>]>([:])

        func read(_ key: String, _ load: () throws -> String?) throws -> String? {
            if let hit = cache.withLock({ $0[key] }) { return try hit.get() }
            let result = Result { try load() }
            cache.withLock { $0[key] = result }
            return try result.get()
        }
    }

    public func build() async -> DoctorReport {
        let resolvedHost = host ?? ResourceProbe().snapshot()

        // The tart probe must honor the config's tart_path override, exactly
        // like the checklist does — the scenario is resolved through the same
        // shared code, so doctor and checklist can never disagree.
        let evaluation = SetupStatusComputer.resolve(config)
        var parsed: KinhinConfig?
        if case .parsed(let cfg) = evaluation { parsed = cfg }

        // Every probe runs once, here, and its answer is handed to the
        // checklist and reused by the sections below (they used to probe the
        // same things again). Independent probes start together.
        let injectedCLT = clt
        let injectedTart = tartHealth
        let tartPath = parsed?.tartPath
        let wantsContainer = parsed?.container != nil
        let wantsDocker = parsed?.docker != nil
        let wantsHost = parsed?.hostRoutesConfigured ?? false
        let injectedContainer = containerHealth
        let injectedDocker = dockerHealth
        let injectedHost = hostHealth
        async let cltProbe: CLTState = {
            if let injectedCLT { return injectedCLT }
            return await CLTProbe().check()
        }()
        async let tartProbe: TartHealth = {
            if let injectedTart { return injectedTart }
            return await TartHealthProbe(configuredPath: tartPath).check()
        }()
        async let containerProbe: RuntimeHealth? = {
            guard wantsContainer else { return nil }
            if let injectedContainer { return injectedContainer }
            return await AppleContainerRuntime().health()
        }()
        async let dockerProbe: RuntimeHealth? = {
            guard wantsDocker else { return nil }
            if let injectedDocker { return injectedDocker }
            return await DockerRuntime(image: parsed?.docker?.image ?? "kinhin-ci-linux").health()
        }()
        async let hostProbe: RuntimeHealth? = {
            guard wantsHost else { return nil }
            if let injectedHost { return injectedHost }
            return await HostRuntime().health()
        }()
        let resolvedCLT = await cltProbe
        let resolvedTart = await tartProbe
        let resolvedContainerHealth = await containerProbe
        let resolvedDockerHealth = await dockerProbe
        let resolvedHostHealth = await hostProbe

        // Image listings (they need the health verdicts), concurrently.
        let containerWanted = parsed?.container?.image
        let dockerConfig = parsed?.docker
        let injectedContainerImages = containerImages
        let injectedDockerImages = dockerImages
        async let containerImagesProbe: [String]? = {
            if let injectedContainerImages { return injectedContainerImages }
            guard containerWanted != nil, resolvedContainerHealth?.isReady == true else { return nil }
            return await AppleContainerRuntime().localImageNames()
        }()
        async let dockerImagesProbe: [String]? = {
            if let injectedDockerImages { return injectedDockerImages }
            guard let dockerConfig, resolvedDockerHealth?.isReady == true else { return nil }
            return await DockerRuntime(image: dockerConfig.image).localImageNames()
        }()
        let resolvedContainerImages = await containerImagesProbe
        let resolvedDockerImages = await dockerImagesProbe
        var dockerArchitecture: String?
        if let dockerConfig, dockerImages == nil, resolvedDockerHealth?.isReady == true,
            (resolvedDockerImages ?? []).contains(where: {
                $0 == dockerConfig.image || $0.hasPrefix("\(dockerConfig.image):")
            })
        {
            dockerArchitecture = await DockerRuntime(image: dockerConfig.image).imageArchitecture(
                of: dockerConfig.image)
        }
        // With the health injected the checklist assumes the kernel is
        // installed; a live run reads it once here.
        let kernelInstalled: Bool? =
            (containerHealth == nil && resolvedContainerHealth?.isReady == true)
            ? AppleContainerRuntime.hasInstalledKernel() : nil

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
        let tokenReads = TokenReads()
        let accountLoad = self.accountLoad
        let sharedAccountLoad: @Sendable (ForgeID, String) throws -> String? = { forge, name in
            try tokenReads.read("\(forge.rawValue):\(name)") { try accountLoad(forge, name) }
        }
        var accountStored: [String: Bool] = [:]
        for account in parsed?.accounts ?? [] {
            accountStored[account.name] = stored("account:\(account.name)") {
                try sharedAccountLoad(account.forge, account.name)
            }
        }
        let detailed = await SetupStatusComputer(
            host: resolvedHost,
            clt: resolvedCLT,
            tartHealth: resolvedTart,
            tartList: tartList,
            config: config,
            accountTokensStored: accountStored,
            tokenReadFailures: tokenFailures,
            containerHealth: resolvedContainerHealth,
            containerImages: resolvedContainerImages,
            containerKernelInstalled: kernelInstalled,
            dockerHealth: resolvedDockerHealth,
            dockerImages: resolvedDockerImages,
            dockerImageArchitecture: dockerArchitecture,
            hostHealth: resolvedHostHealth
        ).computeDetailed()
        let status = detailed.status

        let authReport = AuthStatusReporter.report(config: parsed, load: authLoad, loadAccount: sharedAccountLoad)

        // Apple-container section — present only when the config enables it,
        // with the same image-matching rule the checklist row uses.
        var containerSection: DoctorReport.ContainerSection?
        if let container = parsed?.container {
            let resolvedHealth = resolvedContainerHealth ?? .broken("container health was not probed")
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
            let listed = resolvedContainerImages ?? []
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
            let resolvedHealth = resolvedDockerHealth ?? .broken("docker health was not probed")
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
            let listed = resolvedDockerImages ?? []
            let imageFound = listed.contains { $0 == wanted || $0.hasPrefix("\(wanted):") }
            let imageArch = dockerArchitecture
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
            let resolvedHealth = resolvedHostHealth ?? .broken("host health was not probed")
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

        // The configured tart base image — the same verdict the checklist's
        // base-image row renders (shared classifier, so they cannot drift).
        // The local-VM half of the verdict uses the same tart list the
        // checklist fetched; the fixture (or the live list) may be nil when
        // tart is unavailable, which leaves known references green.
        var tartBaseImageSection: DoctorReport.TartBaseImageSection?
        if let cfg = parsed, cfg.baseImage != nil {
            // The checklist's image row already listed tart (and reports a
            // failed listing): reuse that list. An unreachable tart just
            // leaves known references green and unknown ones unknown.
            let localVMs = tartList ?? detailed.tartVMs ?? []
            let verdict = SetupStatusComputer.baseImageState(cfg: cfg, localVMs: localVMs)
            tartBaseImageSection = DoctorReport.TartBaseImageSection(
                reference: cfg.baseImage ?? "", state: verdict.state, ok: verdict.ok, fix: verdict.fix,
                pinned: TartBaseImage.isDigestPinned(cfg.baseImage ?? ""),
                warning: SetupStatusComputer.baseImageMutabilityNote(cfg.baseImage))
        }

        // Capacity — the same math the human doctor prints, plus job slots.
        // The disk estimate matches the engine's scaler (explicit disk_gb or
        // the runtime default), so doctor's cap is the cap the fleet enforces.
        var capacitySection: DoctorReport.CapacitySection?
        if let cfg = parsed {
            let plan = Capacity.plan(for: cfg, host: resolvedHost)
            capacitySection = DoctorReport.CapacitySection(
                maxConcurrent: plan.maxConcurrent,
                bindingConstraint: plan.bindingConstraint,
                fits: plan.fits,
                jobSlots: plan.maxConcurrent * max(1, cfg.runnersPerVM)
            )
        }

        let security = Self.securitySection(
            config: parsed, softnetInstalled: softnetInstalled, tartHealthy: Self.tartSection(from: resolvedTart).ok,
            hostKeyUnpinned: GuestHostKeyPinning.recordedFallback(
                marker: hostKeyMarker ?? GuestHostKeyPinning.markerURL))

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
            ready: status.ready && authReport.allGood && (security?.ok ?? true),
            capacity: capacitySection,
            tartBaseImage: tartBaseImageSection,
            security: security
        )
    }
}
