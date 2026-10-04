import Foundation
import KinhinKit

// The CLI's routing table, extracted from the entry point so tests can pin
// the command surface (arg parsing must not silently change meaning).
enum CLICommand: Equatable {
    case configInit
    case auth
    case doctor
    case setupStatus
    case setupRepair
    case runtimes
    case imagePrepare
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

    /// Head-token dispatch, preserving the historical quirks: the two-token
    /// forms `config init` and `image prepare` route identically to their
    /// bare heads, `--help`/`-h` are aliases of `help`, and an empty argument
    /// list behaves like `help` (with the unknown-command case handled by the
    /// caller when this returns nil).
    static func parse(_ args: [String]) -> CLICommand? {
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
        case nil:
            return .help
        default:
            return nil
        }
    }

    /// Whether invoking this command should auto-create the starter config
    /// first. Mirrors the original exemption switch: help/version/config are
    /// no-ops that must not touch disk (and `toolchains detect`); everything else (including unknown
    /// commands, which print help before failing) auto-creates.
    static func shouldAutoCreateConfig(_ command: CLICommand?, args: [String] = []) -> Bool {
        // `toolchains detect` and `workflow test` only read a repo; they need no config.
        if command == .toolchains, args.dropFirst().first == "detect" { return false }
        if command == .workflow { return false }
        switch command {
        case .help, .version, .support, .configInit:
            return false
        case .reset:
            // Auto-creating a starter config seconds before deleting it would
            // be absurd (and would print the creation note mid-reset).
            return false
        default:
            return true
        }
    }
}
