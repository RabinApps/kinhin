import Foundation
import KinhinKit

/// `kinhin setup repair host-agent` — installs the actions-runner agent that
/// host-mode routes run on this Mac (the fix `HostRuntime.health()` advertises).
enum SetupRepairCommand {
    static func run(_ args: [String]) async throws {
        guard args.dropFirst().first == "repair", args.dropFirst(2).first == "host-agent" else {
            fail("usage: kinhin setup repair host-agent", exit: .usage)
        }
        Paths.ensureSupportDirectories()
        let installer = HostAgentInstaller()
        if installer.isInstalled {
            print("host runner agent already installed")
            return
        }
        print("installing the GitHub runner agent for host runs…")
        let version = try await installer.install()
        print("installed actions-runner \(version)")
    }
}
