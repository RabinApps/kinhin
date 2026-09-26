import Foundation

// Checklist rows for the optional runtimes (Apple container, Docker, host
// agent). Each appears only when the config enables that runtime.
extension SetupStatusComputer {
    /// Apple-container runtime — rows appear only when the config
    /// enables the container runtime, mirroring the gitea-token row.
    func containerChecks(_ cfg: KinhinConfig, facts: HostFacts) async -> [SetupCheckResult] {
        var checks: [SetupCheckResult] = []
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
        return checks
    }

    /// Docker runtime — rows appear only when the config declares a
    /// `docker:` section, mirroring the container rows above.
    func dockerChecks(_ cfg: KinhinConfig, facts: HostFacts) async -> [SetupCheckResult] {
        var checks: [SetupCheckResult] = []
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
        return checks
    }

    /// Host runtime — the row appears only when a route targets
    /// `host`. The agent must be installed, and the detail keeps the
    /// "unisolated" disclosure in front of the user.
    func hostAgentChecks() async -> [SetupCheckResult] {
        var checks: [SetupCheckResult] = []
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
        return checks
    }
}
