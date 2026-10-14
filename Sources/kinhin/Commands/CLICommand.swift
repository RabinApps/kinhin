import Foundation
import KinhinKit

// The commands the CLI routes to. Which spellings reach each one is declared in
// `CommandCatalog`; this enum is what the dispatcher switches on.
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
    case mobile
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
    case bench
    case reset
    case requeue
    case skip
    case support
    case issue
    case version
    case help
    case workflow
    case video
    case mcp

    /// The command a line routes to by its head tokens, ignoring unknown
    /// subcommands and flags (the historical dispatch: `config bogus` is still
    /// `config`, `image frobnicate` still `image`). Strict validation, aliases
    /// and help live in `CommandResolver`, driven by `CommandCatalog`; an
    /// empty argument list is `help`, an unknown command is nil.
    static func parse(_ args: [String]) -> CLICommand? {
        CommandResolver.lookup(args)
    }

    /// Whether invoking this command should auto-create the starter config
    /// first. Mirrors the original exemption switch: help/version/config are
    /// no-ops that must not touch disk (and `toolchains detect`); everything else (including unknown
    /// commands, which print help before failing) auto-creates.
    static func shouldAutoCreateConfig(_ command: CLICommand?, args: [String] = []) -> Bool {
        // `toolchains detect` and `workflow test` only read a repo; `video` and `mobile init` only write files into one.
        // None of them needs a config. `workflow route` needs an *existing* config (it refuses with the setup
        // command rather than auto-creating a starter the route couldn't use).
        if command == .toolchains, args.dropFirst().first == "detect" { return false }
        if command == .workflow || command == .video || command == .mobile { return false }
        switch command {
        case .help, .version, .support, .issue, .configInit:
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
