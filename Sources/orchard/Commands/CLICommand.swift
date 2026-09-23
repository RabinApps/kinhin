import Foundation
import OrchardKit

// The CLI's routing table, extracted from the entry point so tests can pin
// the command surface (arg parsing must not silently change meaning).
enum CLICommand: Equatable {
    case configInit
    case auth
    case doctor
    case setupStatus
    case runtimes
    case imagePrepare
    case toolchains
    case start
    case stop
    case pause
    case resume
    case status
    case watch
    case logs
    case daemon
    case version
    case help

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
        case "runtimes":
            return .runtimes
        case "image", "image prepare":
            return .imagePrepare
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
        case "logs":
            return .logs
        case "daemon":
            return .daemon
        case "version", "--version", "-v":
            return .version
        case "help", "--help", "-h":
            return .help
        case nil:
            return .help
        default:
            return nil
        }
    }

    /// Whether invoking this command should auto-create the starter config
    /// first. Mirrors the original exemption switch: help/version/config are
    /// no-ops that must not touch disk; everything else (including unknown
    /// commands, which print help before failing) auto-creates.
    static func shouldAutoCreateConfig(_ command: CLICommand?) -> Bool {
        switch command {
        case .help, .version, .configInit:
            return false
        default:
            return true
        }
    }
}
