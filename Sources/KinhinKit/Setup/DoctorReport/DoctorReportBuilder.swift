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
    /// The container listing itself (names *and* sizes) — the one fixture
    /// for that probe, so tests can exercise the disk-usage breakdown.
    let containerImages: ImageInventory.RuntimeImages?
    let dockerHealth: RuntimeHealth?
    /// The docker listing, same shape as `containerImages`.
    let dockerImages: ImageInventory.RuntimeImages?
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
    /// The fleet's runner VM records; nil reads the live store — the same
    /// read `kinhin image list` makes. The prune suggestion needs them so an
    /// image a runner is on is never counted as wastable.
    let fleet: [VMRecord]?
    /// The derived-image index; nil reads the live store. Records classify
    /// configured-derived tart images (never prunable) and mark stale index
    /// entries — again, the `image list` read.
    let projectRecords: [ProjectImageRecord]?
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
        containerImages: ImageInventory.RuntimeImages? = nil,
        dockerHealth: RuntimeHealth? = nil,
        dockerImages: ImageInventory.RuntimeImages? = nil,
        hostHealth: RuntimeHealth? = nil,
        dockerInstalled: Bool? = nil,
        osVersion: OperatingSystemVersion? = nil,
        softnetInstalled: Bool? = nil,
        hostKeyMarker: URL? = nil,
        orgPermissionCheck: @escaping @Sendable (String, String, String?) async -> String = { token, scope, instance in
            await TokenHealthCheck.github(token: token, scope: scope, instance: instance).message
        },
        fleet: [VMRecord]? = nil,
        projectRecords: [ProjectImageRecord]? = nil
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
        self.fleet = fleet
        self.projectRecords = projectRecords
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
        // Immutable: the probes below capture it in concurrent `async let`s.
        let parsed: KinhinConfig?
        if case .parsed(let cfg) = evaluation {
            parsed = cfg
        } else {
            parsed = nil
        }

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
        // The listings come from the shared image inventory — the same
        // "ask a runtime for its images" the checklist's rows and
        // `kinhin image list` use, so the doctor ships no copy of its own.
        async let containerImagesProbe: ImageInventory.RuntimeImages? = {
            if let injectedContainerImages { return injectedContainerImages }
            guard containerWanted != nil, resolvedContainerHealth?.isReady == true else { return nil }
            return await ImageInventory.listing(runtime: .container, config: parsed, sizes: true)
        }()
        async let dockerImagesProbe: ImageInventory.RuntimeImages? = {
            if let injectedDockerImages { return injectedDockerImages }
            guard dockerConfig != nil, resolvedDockerHealth?.isReady == true else { return nil }
            return await ImageInventory.listing(runtime: .docker, config: parsed, sizes: true)
        }()
        let resolvedContainerImages = await containerImagesProbe
        let resolvedDockerImages = await dockerImagesProbe
        var dockerArchitecture: String?
        if let cfg = parsed, let dockerConfig = cfg.docker, dockerImages == nil,
            resolvedDockerHealth?.isReady == true, let listed = resolvedDockerImages
        {
            let found = ImageInventory.section(.docker, config: cfg, images: listed)
                .entries.contains { $0.role == .base && $0.present }
            if found {
                dockerArchitecture = await DockerRuntime(image: dockerConfig.image).imageArchitecture(
                    of: dockerConfig.image)
            }
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
            containerImages: resolvedContainerImages?.names,
            containerKernelInstalled: kernelInstalled,
            dockerHealth: resolvedDockerHealth,
            dockerImages: resolvedDockerImages?.names,
            dockerImageArchitecture: dockerArchitecture,
            hostHealth: resolvedHostHealth
        ).computeDetailed()
        let status = detailed.status

        let authReport = AuthStatusReporter.report(config: parsed, load: authLoad, loadAccount: sharedAccountLoad)

        let containerSection = Self.containerSection(
            config: parsed, health: resolvedContainerHealth, images: resolvedContainerImages)
        let dockerSection = Self.dockerSection(
            config: parsed, health: resolvedDockerHealth, images: resolvedDockerImages,
            imageArchitecture: dockerArchitecture)
        let dockerAvailability = dockerAvailabilitySection(host: resolvedHost)
        let hostSection = Self.hostSection(config: parsed, health: resolvedHostHealth)
        // Shared toolchain cache — directory state only (no live mounts probed).
        let cacheSection = Self.toolchainCacheSection(config: parsed)

        // The local-VM half of the base-image verdict uses the same tart list
        // the checklist fetched.
        let tartImages =
            tartList.map { ImageInventory.RuntimeImages(tartEntries: $0) }
            ?? detailed.tartImages
        let tartBaseImageSection = Self.tartBaseImageSection(config: parsed, tartImages: tartImages)
        let images = imageSections(
            config: parsed, tartImages: tartImages, containerImages: resolvedContainerImages,
            dockerImages: resolvedDockerImages)
        let diskPressure = Self.diskPressureSection(config: parsed, host: resolvedHost)
        let capacitySection = Self.capacitySection(config: parsed, host: resolvedHost)

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
            security: security,
            imageTotalGB: images.totalGB,
            imagePrune: images.prune,
            diskPressure: diskPressure
        )
    }
}
