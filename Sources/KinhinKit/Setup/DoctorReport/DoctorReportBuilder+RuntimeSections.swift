import Foundation

// MARK: - Runtime sections (container, docker, host)

// Each builder is pure: it maps the probe answers `build()` already gathered
// onto one JSON section, so it can be tested without a machine.
extension DoctorReportBuilder {
    /// Apple-container section — present only when the config enables it,
    /// with the same image-matching rule the checklist row uses. With named
    /// pools, every pool's image must be local, and each pool is listed with
    /// its image and whether its shape fits the budget on `host`.
    /// The Docker Hub cache row (`registryCache`) is attached only when some pool uses the cache.
    static func containerSection(
        config cfg: KinhinConfig?, health: RuntimeHealth?, images: ImageInventory.RuntimeImages?,
        host: HostResources? = nil, registryCache: DoctorReport.RegistryCacheStatus? = nil
    ) -> DoctorReport.ContainerSection? {
        guard let cfg, let container = cfg.container else { return nil }
        let verdict = RuntimeSectionVerdict.from(health: health ?? .broken("container health was not probed"))
        let section = images.map { ImageInventory.section(.container, config: cfg, images: $0) }
        var imageFound = section?.configuredImagesPresent ?? false
        var wanted = container.image
        var fix = verdict.fix
        var pools: [DoctorReport.ContainerPoolStatus]?
        if container.pools.isEmpty {
            // A working runtime with a missing image gets the prepare command
            // — the same advice the human doctor prints for that case.
            if verdict.ok, !imageFound { fix = "kinhin image prepare --container --target \(wanted)" }
        } else {
            let budget = host.flatMap { RuntimeCapacity.containerBudget(for: cfg, host: $0) }
            // The pools' own rule, the one the engine and the app use: the tag `container run` starts from. When the
            // images could not be listed, no pool counts as built.
            let listed = images.flatMap { $0.unavailable == nil ? $0.names : nil }
            let unbuilt = listed.map { container.poolsMissingImage(listed: $0) } ?? container.pools
            let unbuiltNames = Set(unbuilt.map(\.name))
            imageFound = listed != nil && unbuilt.isEmpty
            pools = container.pools.map { pool in
                DoctorReport.ContainerPoolStatus(
                    name: pool.name, image: pool.image, imageFound: !unbuiltNames.contains(pool.name),
                    cpus: pool.cpus, memoryGB: pool.memoryGB, max: pool.max, docker: pool.docker,
                    fits: budget.map { $0.count(cpu: pool.cpus, memoryGB: pool.memoryGB) > 0 } ?? true,
                    budgetCPU: budget?.cpu ?? 0, budgetMemoryGB: budget?.memoryGB ?? 0,
                    platform: pool.platform.rawValue, dockerCache: pool.usesDockerCache)
            }
            if let first = unbuilt.first { wanted = first.image }
            if verdict.ok, !imageFound {
                fix =
                    Set(unbuilt.map(\.image)).count == 1
                    ? "kinhin image prepare --container --pool \(unbuilt.first?.name ?? "")"
                    : "kinhin image prepare --container --all"
            }
        }
        return DoctorReport.ContainerSection(
            state: verdict.state, ok: verdict.ok, fix: fix, image: wanted, imageFound: imageFound, pools: pools,
            registryCache: container.usesDockerCache ? registryCache : nil
        )
    }

    /// Docker section — same presence rule, health mapping, image matching,
    /// and prepare-command advice as the container section.
    static func dockerSection(
        config cfg: KinhinConfig?, health: RuntimeHealth?, images: ImageInventory.RuntimeImages?,
        imageArchitecture imageArch: String?
    ) -> DoctorReport.DockerSection? {
        guard let cfg, let docker = cfg.docker else { return nil }
        let verdict = RuntimeSectionVerdict.from(health: health ?? .broken("docker health was not probed"))
        let wanted = docker.image
        let imageFound =
            images.map { images in
                ImageInventory.section(.docker, config: cfg, images: images)
                    .entries.contains { $0.role == .base && $0.present }
            } ?? false
        let archMismatch = imageFound && (imageArch.map { $0 != docker.platform.dockerArchitecture } ?? false)
        var fix = verdict.fix
        if verdict.ok, !imageFound {
            fix = "kinhin image prepare --docker --target \(wanted)"
        } else if verdict.ok, archMismatch, let imageArch {
            fix =
                "image is \(imageArch) but docker.platform is \(docker.platform.rawValue): kinhin image prepare --docker --target \(wanted)"
        }
        return DoctorReport.DockerSection(
            state: verdict.state, ok: verdict.ok, fix: fix, image: wanted, imageFound: imageFound,
            platform: docker.platform.rawValue, imageArchitecture: imageArch,
            note: docker.platform.isEmulated ? LinuxPlatform.emulationNotice : nil
        )
    }

    /// Docker availability — always reported, so Diagnostics can say whether
    /// Docker is installed and supported before it's enabled.
    func dockerAvailabilitySection(host: HostResources) -> DoctorReport.DockerAvailabilitySection {
        let facts = HostFacts(
            resources: host, osVersion: osVersion ?? ProcessInfo.processInfo.operatingSystemVersion)
        let blocked = HostRequirements.blockingReason(for: .docker, on: facts)
        let found: Bool
        if let dockerInstalled {
            found = dockerInstalled
        } else if let dockerHealth {
            if case .missing = dockerHealth { found = false } else { found = true }
        } else {
            found = InstallableTool.docker.isInstalled
        }
        return DoctorReport.DockerAvailabilitySection(installed: found, supported: blocked == nil, reason: blocked)
    }

    /// Host section — present only when a route targets `host`; the
    /// unisolated warning is always attached.
    static func hostSection(config: KinhinConfig?, health: RuntimeHealth?) -> DoctorReport.HostSection? {
        guard let config, config.hostRoutesConfigured else { return nil }
        let verdict = RuntimeSectionVerdict.from(
            health: health ?? .broken("host health was not probed"), missingFix: "kinhin setup repair host-agent")
        return DoctorReport.HostSection(
            state: verdict.state, ok: verdict.ok, fix: verdict.fix,
            routes: (config.runtimes?.routes ?? []).filter { $0.runtime == .host }.map(\.pattern),
            warning: "host routes run repo code directly on this Mac with your privileges, unisolated"
        )
    }
}
