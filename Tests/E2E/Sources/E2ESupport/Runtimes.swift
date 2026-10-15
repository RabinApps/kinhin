import Foundation

/// An execution runtime under test. kinhin's `tart` runtime appears twice, once per guest OS, because a macOS and
/// a Linux guest are baked, labelled and booted differently.
public enum RuntimeKind: String, CaseIterable, Sendable, CustomStringConvertible {
    case docker
    case appleContainer
    case tartMacOS = "tart"
    case tartLinux
    /// No guest at all: the job runs on this Mac, in a scrubbed work directory under the sandbox.
    case host

    public var description: String { rawValue }

    /// The kinhin runtime id (`runtimes:` keys, `kinhin runtimes`) this lane exercises.
    public var kinhinRuntime: String {
        switch self {
        case .docker: return "docker"
        case .appleContainer: return "appleContainer"
        case .tartMacOS, .tartLinux: return "tart"
        case .host: return "host"
        }
    }

    /// The label that selects this pool: the opt-in marker for the marked pools, the OS label for Tart.
    public var runsOn: String {
        switch self {
        case .docker: return "kinhin-docker"
        case .appleContainer: return "kinhin-container"
        case .tartMacOS: return "macos"
        case .tartLinux: return "linux"
        case .host: return "kinhin-host"
        }
    }

    /// The fleet `labels:` a lane on this runtime advertises (the pool adds its marker on top).
    public var fleetLabels: [String] {
        switch self {
        case .docker, .appleContainer, .tartLinux: return ["self-hosted", "linux", "arm64"]
        case .tartMacOS, .host: return ["self-hosted", "macos", "arm64"]
        }
    }

    /// Every label a job asks for, for forges whose jobs name the whole set (GitHub `runs-on`, GitLab `tags`).
    public var jobLabels: [String] {
        fleetLabels.contains(runsOn) ? fleetLabels : fleetLabels + [runsOn]
    }

    /// What the guest's `uname -s` prints, which proves the job ran in the guest and not on this Mac.
    public var guestKernel: String {
        switch self {
        case .docker, .appleContainer, .tartLinux: return "Linux"
        case .tartMacOS, .host: return "Darwin"
        }
    }

    /// False for host mode: the job shares this Mac, so "ran in the guest" is proved by its work directory instead.
    public var isIsolated: Bool { self != .host }

    public var isContainer: Bool { self == .docker || self == .appleContainer }

    public var isTart: Bool { self == .tartMacOS || self == .tartLinux }

    public var isAvailable: Bool {
        switch self {
        case .docker: return E2E.dockerAvailable
        case .appleContainer: return E2E.appleContainerAvailable
        case .tartMacOS: return E2E.tartAvailable && E2E.flag("KINHIN_E2E_TART_BASE") != nil
        case .tartLinux: return E2E.tartAvailable && E2E.flag("KINHIN_E2E_TART_LINUX_BASE") != nil
        // Runs jobs on this Mac. The jobs are the suite's own scripts, but it still downloads runner agents, so it is
        // opt-in like the Tart lanes.
        case .host: return E2E.flag("KINHIN_E2E_HOST") != nil
        }
    }

    public var unavailableReason: String {
        switch self {
        case .docker: return "Docker is not running"
        case .appleContainer: return "the `container` service is not running"
        case .tartMacOS: return "set KINHIN_E2E_TART_BASE to a local macOS tart image to run the Tart macOS lane"
        case .tartLinux:
            return "set KINHIN_E2E_TART_LINUX_BASE (e.g. ghcr.io/cirruslabs/ubuntu:latest) to run the Tart Linux lane"
        case .host: return "set KINHIN_E2E_HOST=1 to run the host lane (jobs run on this Mac)"
        }
    }

    var imageFlags: [String] {
        switch self {
        case .docker: return ["--docker"]
        case .appleContainer: return ["--container"]
        case .tartMacOS, .tartLinux, .host: return []
        }
    }
}

/// The pieces of a fleet `config.yaml` a scenario varies; everything else is a fast, small default.
public struct FleetConfig: Sendable {
    public struct Account: Sendable {
        public var name: String
        public var forge: String
        public var scope: String
        public var instance: String?
        public var allowInsecureHTTP = false
        public var labels: [String]?

        public init(
            name: String, forge: String, scope: String, instance: String? = nil, allowInsecureHTTP: Bool = false,
            labels: [String]? = nil
        ) {
            self.name = name
            self.forge = forge
            self.scope = scope
            self.instance = instance
            self.allowInsecureHTTP = allowInsecureHTTP
            self.labels = labels
        }
    }

    public var accounts: [Account]
    public var runtime: RuntimeKind
    /// The baked image the pool clones (a docker/container image tag, or a Tart image name).
    public var image: String
    public var minRunners = 0
    public var maxRunners = 1
    public var pollInterval = 5
    public var extra = ""

    public init(accounts: [Account], runtime: RuntimeKind, image: String) {
        self.accounts = accounts
        self.runtime = runtime
        self.image = image
    }

    public func yaml() -> String {
        var lines = ["version: 1", "accounts:"]
        for account in accounts {
            lines += ["  - name: \(account.name)", "    forge: \(account.forge)", "    scope: \"\(account.scope)\""]
            if let instance = account.instance { lines.append("    instance: \"\(instance)\"") }
            if account.allowInsecureHTTP { lines.append("    allow_insecure_http: true") }
            if let labels = account.labels {
                lines.append("    labels: [\(labels.map { "\"\($0)\"" }.joined(separator: ", "))]")
            }
        }
        lines += [
            "min_runners: \(minRunners)", "max_runners: \(maxRunners)", "poll_interval: \(pollInterval)",
            "labels: [\(runtime.fleetLabels.map { "\"\($0)\"" }.joined(separator: ", "))]",
        ]
        switch runtime {
        case .docker:
            lines += [
                "runtimes:", "  default: docker", "docker:", "  image: \"\(image)\"", "  base_image: \"ubuntu:24.04\"",
                "  cpus: 2", "  memory_gb: 2", "  max_slots: \(max(1, maxRunners))",
            ]
        case .appleContainer:
            lines += [
                "runtimes:", "  default: appleContainer", "container:", "  image: \"\(image)\"",
                "  base_image: \"ubuntu:24.04\"", "  cpus: 2", "  memory_gb: 2",
            ]
        case .tartMacOS, .tartLinux:
            lines += ["image: \"\(image)\"", "vm_boot_timeout: 600"]
        case .host:
            // `default: host` is rejected (host is never a fallback), so the default stays tart and every account's
            // repository is routed to the host with consent. A `min_runners` floor would land in the default pool,
            // which is why host lanes run without one.
            lines += ["runtimes:", "  default: tart", "  routes:"]
            for account in accounts {
                lines += ["    - pattern: \"\(account.scope)\"", "      runtime: host", "      consent: true"]
            }
        }
        if !extra.isEmpty { lines.append(extra) }
        return lines.joined(separator: "\n") + "\n"
    }
}

/// Looks at the runtimes' instances from outside kinhin, to prove teardown and catch leaks.
public enum Instances {
    /// Names of runner containers/VMs whose image matches `image` (Docker), so only a sandbox's own are counted.
    public static func docker(image: String) async -> [String] {
        let result = try? await Shell.run(
            "docker", ["ps", "-a", "--filter", "ancestor=\(image)", "--format", "{{.Names}}"], timeout: 30)
        return (result?.trimmedStdout ?? "").split(separator: "\n").map(String.init)
    }

    /// Apple containers built from `image`.
    public static func appleContainers(image: String) async -> [String] {
        let result = try? await Shell.run("container", ["list", "--all", "--format", "json"], timeout: 30)
        guard let data = result?.stdout.data(using: .utf8),
            let list = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]]
        else { return [] }
        return list.compactMap { entry -> String? in
            guard let configuration = entry["configuration"] as? [String: Any],
                let id = configuration["id"] as? String,
                let imageInfo = configuration["image"] as? [String: Any],
                let descriptor = imageInfo["descriptor"] as? [String: Any],
                let annotations = descriptor["annotations"] as? [String: String],
                (annotations["com.apple.containerization.image.name"] ?? "").hasPrefix(image)
            else { return nil }
            return id
        }
    }

    /// The prefix this suite's daemon gives every instance it mints (`KINHIN_INSTANCE_PREFIX`, see `Sandbox.environment`).
    /// A real fleet's `kinhin-*` instances never carry it, so the suite neither adopts nor deletes them.
    public static let ownPrefix = "ke2e-"
    /// A real kinhin install's prefix. Tart lanes still refuse to run beside these: Apple caps macOS VMs at two per Mac.
    public static let fleetPrefix = "kinhin-"

    /// Tart VMs with `prefix` (Tart does not record a clone's source, so the prefix is the only owner marker).
    public static func tartClones(prefix: String) async -> [String] {
        let result = try? await Shell.run("tart", ["list", "--source", "local", "--format", "json"], timeout: 30)
        guard let data = result?.stdout.data(using: .utf8),
            let list = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]]
        else { return [] }
        return list.compactMap { $0["Name"] as? String }.filter { $0.hasPrefix(prefix) }
    }

    /// Host-mode instances: the work directories under a sandbox's `host-instances` (`image` is the sandbox's
    /// support directory for the host lane).
    public static func hostInstances(supportDirectory: String) -> [String] {
        let base = URL(fileURLWithPath: supportDirectory).appendingPathComponent("host-instances")
        let entries = (try? FileManager.default.contentsOfDirectory(atPath: base.path)) ?? []
        return entries.filter { $0.hasPrefix(ownPrefix) }
    }

    public static func running(_ runtime: RuntimeKind, image: String) async -> [String] {
        switch runtime {
        case .docker: return await docker(image: image)
        case .appleContainer: return await appleContainers(image: image)
        case .tartMacOS, .tartLinux: return await tartClones(prefix: ownPrefix)
        case .host: return hostInstances(supportDirectory: image)
        }
    }

    /// Instances that would stop `runtime` from being a clean lane: leftovers of an earlier e2e run (`ke2e-*`) on
    /// that runtime, and for Tart also a real fleet's macOS/Linux VMs (`kinhin-*`), since Tart's VM cap is per Mac.
    /// A Docker or Apple container lane ignores a real fleet entirely: kinhin tells its instances apart by prefix.
    public static func foreign(for runtime: RuntimeKind) async -> [String] {
        var found: [String] = []
        switch runtime {
        case .docker where E2E.dockerAvailable:
            let result = try? await Shell.run("docker", ["ps", "-a", "--format", "{{.Names}}"], timeout: 30)
            found += (result?.trimmedStdout ?? "").split(separator: "\n").map(String.init)
                .filter { $0.hasPrefix(ownPrefix) }.map { "docker:\($0)" }
        case .appleContainer where E2E.appleContainerAvailable:
            let result = try? await Shell.run("container", ["list", "--all", "--quiet"], timeout: 30)
            found += (result?.trimmedStdout ?? "").split(separator: "\n").map(String.init)
                .filter { $0.hasPrefix(ownPrefix) }.map { "container:\($0)" }
        case .tartMacOS, .tartLinux:
            guard E2E.tartAvailable else { break }
            found += await tartClones(prefix: ownPrefix).map { "tart:\($0)" }
            found += await tartClones(prefix: fleetPrefix).map { "tart:\($0)" }
        default:
            break
        }
        return found
    }

    /// Force-removes every instance of `image`. The teardown guard for crashed or failed runs.
    public static func removeAll(_ runtime: RuntimeKind, image: String) async {
        let names = await running(runtime, image: image)
        switch runtime {
        case .docker:
            guard !names.isEmpty else { return }
            _ = try? await Shell.run("docker", ["rm", "-f"] + names, timeout: 60)
        case .appleContainer:
            for name in names {
                _ = try? await Shell.run("container", ["stop", name], timeout: 60)
                _ = try? await Shell.run("container", ["delete", "--force", name], timeout: 60)
            }
        case .tartMacOS, .tartLinux:
            for name in names {
                _ = try? await Shell.run("tart", ["stop", name], timeout: 120)
                _ = try? await Shell.run("tart", ["delete", name], timeout: 120)
            }
        case .host:
            // The runner agents live in the sandbox, so their command lines name it.
            _ = try? await Shell.run("pkill", ["-f", "\(image)/host-runner/"], timeout: 30)
            let base = URL(fileURLWithPath: image).appendingPathComponent("host-instances")
            for name in names { try? FileManager.default.removeItem(at: base.appendingPathComponent(name)) }
        }
    }
}
