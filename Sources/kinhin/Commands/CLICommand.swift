import Foundation
import KinhinKit

// The CLI's routing table, extracted from the entry point so tests can pin
// the command surface (arg parsing must not silently change meaning).
enum CLICommand: Equatable, Hashable {
    case configInit
    case auth
    case doctor
    case setupStatus
    case setupRepair
    case runtimes
    case imagePrepare
    case imageList
    case imageDelete
    case imagePrune
    case imageDigest
    case toolchains
    case start
    case stop
    case pause
    case resume
    case status
    case watch
    case pipeline
    case logs
    case daemon
    case cleanup
    case reset
    case requeue
    case skip
    case support
    case version
    case help
    case workflow
    case mcp

    /// `"<head> <subcommand>"` pairs that are commands of their own. Only the
    /// `image` head needs this: `image prepare` still means bare `image`, but
    /// `image list`, `image delete`, `image prune` and `image digest` must not
    /// fall through to it (routing them to prepare would start a bake).
    private static let twoTokenHeads: [String: CLICommand] = [
        "image list": .imageList,
        "image ls": .imageList,
        "image delete": .imageDelete,
        "image rm": .imageDelete,
        "image prune": .imagePrune,
        "image digest": .imageDigest,
    ]

    /// Head-token dispatch, preserving the historical quirks: the two-token
    /// forms `config init` and `image prepare` route identically to their
    /// bare heads, `--help`/`-h` are aliases of `help`, and an empty argument
    /// list behaves like `help` (with the unknown-command case handled by the
    /// caller when this returns nil).
    static func parse(_ args: [String]) -> CLICommand? {
        if args.count >= 2, let matched = twoTokenHeads["\(args[0]) \(args[1])"] {
            return matched
        }
        switch args.first {
        case "config", "config init":
            return .configInit
        case "auth":
            return .auth
        case "doctor":
            return .doctor
        case "setup-status":
            return .setupStatus
        case "setup":
            return .setupRepair
        case "runtimes":
            return .runtimes
        case "image", "image prepare":
            return .imagePrepare
        // A quoted two-token head (`kinhin "image digest"`); the split form
        // is handled by `twoTokenHeads` above.
        case "image digest":
            return .imageDigest
        case "toolchains":
            return .toolchains
        case "start":
            return .start
        case "stop":
            return .stop
        case "pause":
            return .pause
        case "resume":
            return .resume
        case "status":
            return .status
        case "watch":
            return .watch
        case "pipeline", "pipelines":
            return .pipeline
        case "logs":
            return .logs
        case "daemon":
            return .daemon
        case "cleanup":
            return .cleanup
        case "reset":
            return .reset
        case "requeue":
            return .requeue
        case "skip":
            return .skip
        case "support", "sponsor":
            return .support
        case "version", "--version", "-v":
            return .version
        case "help", "--help", "-h":
            return .help
        case "workflow", "workflow test":
            return .workflow
        case "mcp":
            return .mcp
        case nil:
            return .help
        default:
            return nil
        }
    }

    /// Commands that take no help flag of their own: `--help`/`-h` after the
    /// command name must print help, not run the command (`kinhin stop --help`
    /// used to stop the fleet).
    private static let helpIntercepted: Set<CLICommand> = [
        .start, .stop, .pause, .resume, .status, .daemon, .cleanup, .watch, .logs,
    ]

    static func wantsHelp(_ command: CLICommand?, args: [String]) -> Bool {
        guard let command, helpIntercepted.contains(command) else { return false }
        return args.dropFirst().contains { $0 == "--help" || $0 == "-h" }
    }

    /// Whether invoking this command should auto-create the starter config
    /// first. Mirrors the original exemption switch: help/version/config are
    /// no-ops that must not touch disk (and `toolchains detect`); everything else (including unknown
    /// commands, which print help before failing) auto-creates.
    static func shouldAutoCreateConfig(_ command: CLICommand?, args: [String] = []) -> Bool {
        // `toolchains detect` and `workflow test` only read a repo; they need no config.
        // `workflow route` needs an *existing* config (it refuses with the setup
        // command rather than auto-creating a starter the route couldn't use).
        if command == .toolchains, args.dropFirst().first == "detect" { return false }
        if command == .workflow { return false }
        switch command {
        case .help, .version, .support, .configInit:
            return false
        case .reset:  // Auto-creating a starter config seconds before deleting it would
            // be absurd (and would print the creation note mid-reset).
            return false
        case .mcp:
            // A stdio server must not touch disk on boot; its tools report a
            // missing config instead ("run: kinhin config init").
            return false
        default:
            return true
        }
    }
}
