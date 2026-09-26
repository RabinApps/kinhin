import Foundation

/// The host facts an install option's requirements are judged against.
public struct HostFacts: Sendable {
    let arm64: Bool
    let memoryGB: Int
    let osVersion: OperatingSystemVersion

    init(arm64: Bool, memoryGB: Int, osVersion: OperatingSystemVersion) {
        self.arm64 = arm64
        self.memoryGB = memoryGB
        self.osVersion = osVersion
    }

    init(resources: HostResources, osVersion: OperatingSystemVersion = ProcessInfo.processInfo.operatingSystemVersion) {
        self.init(arm64: resources.arm64, memoryGB: resources.memoryGB, osVersion: osVersion)
    }

    public static func current() -> HostFacts { HostFacts(resources: ResourceProbe().snapshot()) }

    var osLabel: String {
        let v = osVersion
        return v.patchVersion == 0
            ? "\(v.majorVersion).\(v.minorVersion)" : "\(v.majorVersion).\(v.minorVersion).\(v.patchVersion)"
    }
}

/// Whether this Mac can run what an install option would install.
public enum RequirementVerdict: Equatable, Sendable {
    case supported
    /// Installs, but outside the vendor's supported range; the string says why.
    case limited(String)
    /// Would install something that cannot run here; the string says why.
    case unsupported(String)

    public var isUnsupported: Bool {
        if case .unsupported = self { return true }
        return false
    }

    /// The user-facing reason, when there is one.
    public var reason: String? {
        switch self {
        case .supported: return nil
        case .limited(let why), .unsupported(let why): return why
        }
    }
}

public enum HostRequirements {
    /// Apple container needs Apple silicon and macOS 26; its maintainers do
    /// not support older releases (https://github.com/apple/container).
    static let containerMinimumMacOS = 26
    /// Docker Desktop supports the current macOS and the two before it, so
    /// this floor moves yearly: below it, warn rather than block.
    static let dockerDesktopMinimumMacOS = 15
    static let dockerDesktopMinimumMemoryGB = 4

    /// Judges one install option against the host. Options without known
    /// requirements (tart, OrbStack, colima) are supported on every Mac
    /// kinhin itself runs on.
    public static func verdict(for option: InstallOption, on host: HostFacts) -> RequirementVerdict {
        switch option.id {
        case "container-brew":
            guard host.arm64 else { return .unsupported("Apple container needs a Mac with Apple silicon.") }
            guard host.osVersion.majorVersion >= containerMinimumMacOS else {
                return .unsupported(
                    "Apple container needs macOS \(containerMinimumMacOS) or later (this Mac runs \(host.osLabel)).")
            }
            return .supported
        case "docker-desktop":
            guard host.memoryGB >= dockerDesktopMinimumMemoryGB else {
                return .unsupported(
                    "Docker Desktop needs at least \(dockerDesktopMinimumMemoryGB) GB of RAM (this Mac has \(host.memoryGB) GB)."
                )
            }
            guard host.osVersion.majorVersion >= dockerDesktopMinimumMacOS else {
                return .limited(
                    "Docker Desktop supports macOS \(dockerDesktopMinimumMacOS) or later (this Mac runs \(host.osLabel)); the install may fail."
                )
            }
            return .supported
        default:
            return .supported
        }
    }

    /// Why none of a tool's install options can run here, or nil when at
    /// least one can.
    public static func blockingReason(for tool: InstallableTool, on host: HostFacts) -> String? {
        let verdicts = RuntimeInstaller.options(for: tool).map { verdict(for: $0, on: host) }
        guard !verdicts.isEmpty, verdicts.allSatisfy(\.isUnsupported) else { return nil }
        return verdicts.compactMap(\.reason).first
    }

    /// The options worth offering on this host: unsupported ones are dropped,
    /// and a limited one carries its warning in its detail.
    public static func offeredOptions(for tool: InstallableTool, on host: HostFacts) -> [InstallOption] {
        RuntimeInstaller.options(for: tool).compactMap { option in
            switch verdict(for: option, on: host) {
            case .supported:
                return option
            case .unsupported:
                return nil
            case .limited(let warning):
                return InstallOption(
                    id: option.id, title: option.title, detail: "\(option.detail) ⚠︎ \(warning)",
                    commands: option.commands, postInstall: option.postInstall, needsBrew: option.needsBrew,
                    manualURL: option.manualURL)
            }
        }
    }

    /// Throws when no install option for the tool can run on this host.
    public static func ensureSupported(_ tool: InstallableTool, on host: HostFacts = .current()) throws {
        if let reason = blockingReason(for: tool, on: host) { throw RuntimeInstallerError.unsupportedHost(reason) }
    }
}
