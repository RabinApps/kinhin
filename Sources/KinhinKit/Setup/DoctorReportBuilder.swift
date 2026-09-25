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
    let authLoad: @Sendable (ForgeID) -> String?
    /// Same, for the named `accounts:` entries.
    let accountLoad: @Sendable (ForgeID, String) -> String?
    let containerHealth: RuntimeHealth?
    let containerImages: [String]?
    let dockerHealth: RuntimeHealth?
    let dockerImages: [String]?

    public init(
        host: HostResources? = nil,
        clt: CLTState? = nil,
        tartHealth: TartHealth? = nil,
        tartList: [TartVM]? = nil,
        config: ConfigScenario = .live,
        authLoad: @escaping @Sendable (ForgeID) -> String? = { KeychainTokenStore.load(forge: $0) },
        accountLoad: @escaping @Sendable (ForgeID, String) -> String? = {
            KeychainTokenStore.load(forge: $0, name: $1)
        },
        containerHealth: RuntimeHealth? = nil,
        containerImages: [String]? = nil,
        dockerHealth: RuntimeHealth? = nil,
        dockerImages: [String]? = nil
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
        // source of truth (live → real Keychain, tests → fixture).
        let status = await SetupStatusComputer(
            host: resolvedHost,
            clt: resolvedCLT,
            tartHealth: resolvedTart,
            tartList: tartList,
            config: config,
            tokenStored: authLoad(.github) != nil,
            giteaTokenStored: authLoad(.gitea) != nil,
            accountTokensStored: Dictionary(
                uniqueKeysWithValues: (parsed?.accounts ?? []).map { ($0.name, accountLoad($0.forge, $0.name) != nil) }),
            containerHealth: containerHealth,
            containerImages: containerImages,
            dockerHealth: dockerHealth,
            dockerImages: dockerImages
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

        // Shared toolchain cache — directory state only (no live mounts
        // probed; runners mount on demand). The per-ecosystem breakdown
        // covers the subdirectories the config's toolchains selection uses,
        // falling back to all top-level directories with content.
        let cacheSection = Self.toolchainCacheSection(config: parsed)

        // Capacity — the same math the human doctor prints, plus job slots.
        var capacitySection: DoctorReport.CapacitySection?
        if let cfg = parsed {
            let plan = Capacity.plan(
                host: resolvedHost,
                vmCPU: cfg.vm.cpuCount,
                vmMemoryGB: cfg.vm.memoryGB,
                reservedCPU: cfg.reserve.cpu,
                reservedMemoryGB: cfg.reserve.memoryGB,
                diskPerVMGB: cfg.diskGB ?? 0,
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
            toolchainCache: cacheSection,
            auth: authReport,
            checks: status.checks,
            ready: status.ready && authReport.allGood,
            capacity: capacitySection
        )
    }

    /// Measures the host toolchain cache: usability, total bytes, and the
    /// per-ecosystem breakdown for the directories the config's selection
    /// maps to (or all populated top-level directories when nothing is
    /// selected). Pure filesystem reads — never creates or deletes anything.
    /// Public so the human doctor prints exactly the JSON document's data.
    public static func toolchainCacheSection(config: KinhinConfig?) -> DoctorReport.ToolchainCacheSection {
        let root = Paths.toolchainCache
        let fm = FileManager.default
        var isDir: ObjCBool = false
        var isUsable = fm.fileExists(atPath: root.path, isDirectory: &isDir) && isDir.boolValue
        if isUsable, !fm.isWritableFile(atPath: root.path) {
            isUsable = false
        }
        guard isUsable else {
            let shareCacheOn = config?.toolchains?.shareCache ?? false
            return DoctorReport.ToolchainCacheSection(
                root: root.path, usable: false, sharedWithRunners: shareCacheOn,
                warning: shareCacheOn, totalBytes: 0, ecosystems: []
            )
        }

        // The subdirectories the config's toolchains selection maps to
        // (Linux path irrelevant here — subdirectories are shared).
        let selected: [String]?
        if let toolchains = config?.toolchains {
            let selection = ToolchainCatalog.selection(from: toolchains)
            let dirs = selection.cacheEnvs.map(\.subdirectory)
            selected = dirs.isEmpty ? nil : dirs
        } else {
            selected = nil
        }

        var ecosystems: [DoctorReport.ToolchainCacheSection.Ecosystem] = []
        var total: Int64 = 0
        if let selected {
            for directory in selected {
                let bytes = Self.directorySize(at: root.appendingPathComponent(directory))
                ecosystems.append(.init(directory: directory, bytes: bytes))
                total += bytes
            }
        } else {
            // No selection: report every populated top-level directory.
            let children =
                (try? fm.contentsOfDirectory(
                    at: root, includingPropertiesForKeys: [.isDirectoryKey, .totalFileAllocatedSizeKey])) ?? []
            for child in children.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
                let bytes = Self.directorySize(at: child)
                guard bytes > 0 else { continue }
                ecosystems.append(.init(directory: child.lastPathComponent, bytes: bytes))
                total += bytes
            }
        }
        let shareCacheOn = config?.toolchains?.shareCache ?? false
        let warning = shareCacheOn && total == 0
        return DoctorReport.ToolchainCacheSection(
            root: root.path, usable: true, sharedWithRunners: shareCacheOn,
            warning: warning, totalBytes: total, ecosystems: ecosystems
        )
    }

    /// Recursive byte size of a directory (0 when missing). Follows the
    /// same pruning-friendly convention: regular files only.
    static func directorySize(at url: URL) -> Int64 {
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(at: url, includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey])
        else { return 0 }
        var total: Int64 = 0
        for case let fileURL as URL in enumerator {
            guard let values = try? fileURL.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]),
                values.isRegularFile == true
            else { continue }
            total += Int64(values.fileSize ?? 0)
        }
        return total
    }

    /// Maps CLTState to the JSON section, carrying the shared repair lines.
    static func cltSection(from state: CLTState) -> DoctorReport.CLTSection {
        switch state {
        case .ok(let version):
            return DoctorReport.CLTSection(state: "ok", version: version, ok: true, fixCommand: nil, fixHint: nil)
        case .outdated(let version, _):
            return DoctorReport.CLTSection(
                state: "outdated", version: version, ok: false,
                fixCommand: CLTRepair.commandLine, fixHint: CLTRepair.fallbackHint
            )
        case .missing:
            return DoctorReport.CLTSection(
                state: "missing", version: nil, ok: false,
                fixCommand: CLTRepair.commandLine, fixHint: nil
            )
        case .unselected:
            return DoctorReport.CLTSection(
                state: "unselected", version: nil, ok: false,
                fixCommand: CLTRepair.commandLine, fixHint: nil
            )
        }
    }

    /// Maps TartHealth to the JSON section with the ordered repair lines.
    static func tartSection(from health: TartHealth) -> DoctorReport.TartSection {
        switch health {
        case .healthy:
            return DoctorReport.TartSection(state: "healthy", ok: true, reason: nil, repairCommands: [])
        case .missing:
            return DoctorReport.TartSection(
                state: "missing", ok: false, reason: nil,
                repairCommands: TartHealthProbe.repairs(for: .missing).map(\.commandLine)
            )
        case .killedOnLaunch:
            return DoctorReport.TartSection(
                state: "killedOnLaunch", ok: false,
                reason: "Gatekeeper blocked the un-notarized binary (openai/homebrew-tools#27)",
                repairCommands: TartHealthProbe.repairs(for: .killedOnLaunch).map(\.commandLine)
            )
        case .broken(let reason):
            return DoctorReport.TartSection(
                state: "broken", ok: false, reason: reason,
                repairCommands: TartHealthProbe.repairs(for: .broken(reason)).map(\.commandLine)
            )
        }
    }
}
