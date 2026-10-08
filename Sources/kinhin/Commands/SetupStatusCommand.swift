import Foundation
import KinhinKit

enum SetupStatusCommand {
    /// Exit 0 when ready, 1 while something needs attention. `--quiet` prints
    /// nothing; `--json` prints the checklist document either way.
    static func run(_ args: [String]) async throws {
        Paths.ensureSupportDirectories()
        let setup = await SetupStatusComputer().compute()
        let quiet = args.contains("--quiet") || args.contains("-q")
        if !quiet {
            if args.contains("--json") {
                try emitJSON(setup)
            } else {
                for line in render(setup) { print(line) }
            }
        }
        if !setup.ready { exit(CLIExit.needsAttention.rawValue) }
    }

    /// The human checklist, one line per check, then the verdict.
    static func render(_ setup: SetupStatus) -> [String] {
        var lines: [String] = []
        for check in setup.checks {
            let mark = check.ok ? "✓" : "✗"
            let act =
                check.action.map { action in
                    "  → \(SetupAction.title(for: action))" + (cliCommand(for: action).map { " (\($0))" } ?? "")
                } ?? ""
            lines.append("  [\(mark)] \(check.title): \(check.detail)\(act)")
        }
        lines.append("ready: \(setup.ready ? "yes — kinhin start when you're ready" : "no")")
        return lines
    }

    /// The CLI command that performs an action, for the ones it can.
    static func cliCommand(for action: String) -> String? {
        switch action {
        case "install_tart": return "kinhin setup repair tart"
        case "install_container_cli": return "kinhin setup repair container"
        case "install_docker": return "kinhin setup repair docker"
        case "install_host_agent": return "kinhin setup repair host-agent"
        case "create_config": return "kinhin config init"
        case "enter_account_token", "replace_account_token": return "kinhin auth set"
        case "prepare_image": return "kinhin image prepare"
        case "prepare_container_image": return "kinhin image prepare --container"
        case "prepare_docker_image": return "kinhin image prepare --docker"
        case "fix_base_image": return "edit base_image: in config.yaml"
        default: return nil
        }
    }
}
