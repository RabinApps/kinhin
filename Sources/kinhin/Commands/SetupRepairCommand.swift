import Foundation
import KinhinKit

/// `kinhin setup repair <target>`: installs what the checklist says is
/// missing. `host-agent` installs the runner agents that host-mode routes run
/// on (the fix `HostRuntime.health()` advertises); `docker`, `container` and
/// `tart` install that runtime through the same `RuntimeInstaller` the app's
/// This Mac form uses.
enum SetupRepairCommand {
    static let usage =
        "usage: kinhin setup repair host-agent | docker [--method desktop|orbstack|colima] | container | tart"

    static func run(_ args: [String]) async throws {
        guard args.dropFirst().first == "repair", let target = args.dropFirst(2).first else {
            fail(usage, exit: .usage)
        }
        if target == "host-agent" {
            try await installHostAgent()
            return
        }
        guard let tool = tool(named: target) else { fail(usage, exit: .usage) }
        let method = flag("--method", in: args)
        if let method {
            let valid = RuntimeInstaller.options(for: tool).map(\.method)
            guard valid.contains(method) else {
                fail(
                    "'\(method)' is not a way to install \(tool.title). Use one of: \(valid.joined(separator: ", "))",
                    exit: .usage)
            }
        }
        try await install(tool, method: method)
    }

    static func tool(named name: String) -> InstallableTool? {
        switch name {
        case "docker": return .docker
        case "container": return .appleContainer
        case "tart": return .tart
        default: return nil
        }
    }

    // MARK: - Runtimes

    /// Installs a runtime unless it's already there. Every dependency is
    /// injectable so tests never run Homebrew or exit the process.
    static func install(
        _ tool: InstallableTool, method: String?,
        host: HostFacts = .current(), shell: ShellRunning = Shell(), brew: String? = RuntimeInstaller.brewPath,
        isInstalled: (InstallableTool) -> Bool = { $0.isInstalled },
        output: (String) -> Void = { print($0) }, warning: (String) -> Void = { warn($0) }
    ) async throws {
        if isInstalled(tool) {
            output("\(tool.title) is already installed")
            return
        }
        let option = try RuntimeInstaller.option(for: tool, method: method, on: host)
        if case .limited(let reason) = HostRequirements.verdict(for: option, on: host) { warning(reason) }
        output("installing \(option.title): \(option.commandLine)")
        try await RuntimeInstaller.install(
            option, tool: tool, shell: shell, brew: brew, host: host, isInstalled: isInstalled)
        output("installed \(tool.title). \(option.detail)")
    }

    // MARK: - Host agent

    private static func installHostAgent() async throws {
        Paths.ensureSupportDirectories()
        let installer = HostAgentInstaller()
        if installer.isInstalled {
            print("host runner agent already installed")
            return
        }
        print("installing the runner agents for host runs…")
        let versions = try await installer.install()
        print("installed \(installer.installedSummary(versions))")
    }
}
