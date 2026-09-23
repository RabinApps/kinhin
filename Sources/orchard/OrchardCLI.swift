import Foundation
import OrchardKit

// CLI entry point. Declared with @main (not main.swift) so the executable
// target is importable from unit tests; OrchardKitTests-style suites live in
// Tests/OrchardCLITests. @MainActor preserves the main-thread semantics of
// top-level code — RunCommands.start parks on the main queue (SIGINT source +
// dispatchMain) and depends on it.
//
// First-run convenience: any command materializes the starter config
// (never overwriting an existing file). The note goes to stderr so
// machine-readable output like `setup-status --json` stays clean.
// Exempt: no-ops that shouldn't touch disk, and `config init` itself
// (which has its own exists/--force handling and must not be told the
// auto-created file "already exists").
@MainActor
@main
struct OrchardCLI {
    static func main() async {
        let args = Array(CommandLine.arguments.dropFirst())
        let command = CLICommand.parse(args)

        if CLICommand.shouldAutoCreateConfig(command) {
            noteAutoCreatedConfigIfMissing()
        }

        // Dispatch. Bodies live in Commands/ — routing lives in CLICommand.
        do {
            switch command {
            case .configInit:
                try ConfigCommands.configInit(args)

            case .auth:
                try await AuthCommand.run(args)

            case .doctor:
                try await DoctorCommand.run(args)

            case .setupStatus:
                try await SetupStatusCommand.run(args)

            case .runtimes:
                await RuntimesCommand.run(args)

            case .imagePrepare:
                try await ImageCommand.run(args)

            case .toolchains:
                do {
                    if args.dropFirst().first == "prune" {
                        await ToolchainsCommand.prune(Array(args.dropFirst()))
                    } else {
                        await ToolchainsCommand.run(args)
                    }
                }

            case .start:
                try await RunCommands.start(args)

            case .stop:
                try RunCommands.stop(args)

            case .pause:
                try RunCommands.pauseResume("pause", args: args)

            case .resume:
                try RunCommands.pauseResume("resume", args: args)

            case .status:
                try await RunCommands.status(args)

            case .watch:
                await RunCommands.watch(args)

            case .logs:
                RunCommands.logs(args)

            case .daemon:
                try await RunCommands.daemon(args)

            case .version:
                print("orchard \(OrchardVersion.current)")

            case .help:
                printHelp()

            case nil:
                printHelp()
                fail("unknown command '\(args.first ?? "")'")
            }
        } catch {
            fail(error.localizedDescription)
        }
    }
}
