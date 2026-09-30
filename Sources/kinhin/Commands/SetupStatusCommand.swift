import Foundation
import KinhinKit

enum SetupStatusCommand {
    static func run(_ args: [String]) async throws {
        Paths.ensureSupportDirectories()
        let setup = await SetupStatusComputer().compute()
        if args.contains("--json") {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(setup)
            print(String(decoding: data, as: UTF8.self))
        } else {
            for check in setup.checks {
                let mark = check.ok ? "✓" : "✗"
                let act =
                    check.action.map { action in
                        "  → \(SetupAction.title(for: action))" + (cliCommand(for: action).map { " (\($0))" } ?? "")
                    } ?? ""
                print("  [\(mark)] \(check.title): \(check.detail)\(act)")
            }
            print("ready: \(setup.ready ? "yes — kinhin start when you're ready" : "no")")
        }
    }

    /// The CLI command that performs an action, for the ones it can.
    static func cliCommand(for action: String) -> String? {
        switch action {
        case "install_tart": return "kinhin setup repair tart"
        case "install_container_cli": return "kinhin setup repair container"
        case "install_docker": return "kinhin setup repair docker"
        case "install_host_agent": return "kinhin setup repair host-agent"
        case "fix_base_image": return "edit base_image: in config.yaml"
        default: return nil
        }
    }
}
