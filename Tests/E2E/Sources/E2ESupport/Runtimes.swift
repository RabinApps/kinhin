import Foundation

/// An execution runtime under test.
public enum RuntimeKind: String, CaseIterable, Sendable, CustomStringConvertible {
    case docker
    case appleContainer
    case tartMacOS = "tart"

    public var description: String { rawValue }

    /// The `runs-on` label a workflow uses to opt in to this pool.
    public var runsOn: String {
        switch self {
        case .docker: return "kinhin-docker"
        case .appleContainer: return "kinhin-container"
        case .tartMacOS: return "macos"
        }
    }

    /// What the guest's `uname -s` prints, which proves the job ran in the guest and not on this Mac.
    public var guestKernel: String {
        switch self {
        case .docker, .appleContainer: return "Linux"
        case .tartMacOS: return "Darwin"
        }
    }

    public var isAvailable: Bool {
        switch self {
        case .docker: return E2E.dockerAvailable
        case .appleContainer: return E2E.appleContainerAvailable
        case .tartMacOS: return E2E.tartAvailable && E2E.flag("KINHIN_E2E_TART_BASE") != nil
        }
    }

    public var unavailableReason: String {
        switch self {
        case .docker: return "Docker is not running"
        case .appleContainer: return "the `container` service is not running"
        case .tartMacOS: return "set KINHIN_E2E_TART_BASE to a local macOS tart image to run the Tart lane"
        }
    }

    var imageFlags: [String] {
        switch self {
        case .docker: return ["--docker"]
        case .appleContainer: return ["--container"]
        case .tartMacOS: return []
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
            "labels: [\"self-hosted\", \"linux\", \"arm64\"]",
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
        case .tartMacOS:
            lines += ["image: \"\(image)\"", "vm_boot_timeout: 600"]
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

    public static func running(_ runtime: RuntimeKind, image: String) async -> [String] {
        switch runtime {
        case .docker: return await docker(image: image)
        case .appleContainer: return await appleContainers(image: image)
        case .tartMacOS: return []
        }
    }

    /// Force-removes every instance of `image`. The teardown guard for crashed or failed runs.
    public static func removeAll(_ runtime: RuntimeKind, image: String) async {
        let names = await running(runtime, image: image)
        guard !names.isEmpty else { return }
        switch runtime {
        case .docker: _ = try? await Shell.run("docker", ["rm", "-f"] + names, timeout: 60)
        case .appleContainer:
            for name in names {
                _ = try? await Shell.run("container", ["stop", name], timeout: 60)
                _ = try? await Shell.run("container", ["delete", "--force", name], timeout: 60)
            }
        case .tartMacOS: break
        }
    }
}
