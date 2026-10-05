import Foundation
import KinhinKit

// CLI entry point. Declared with @main (not main.swift) so the executable
// target is importable from unit tests; KinhinKitTests-style suites live in
// Tests/KinhinCLITests. @MainActor preserves the main-thread semantics of
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
struct KinhinCLI {
    static func main() async {
        let args = Array(CommandLine.arguments.dropFirst())
        let command = CLICommand.parse(args)

        if CLICommand.shouldAutoCreateConfig(command, args: args) {
            noteAutoCreatedConfigIfMissing()
        }

        // Dispatch. Bodies live in Commands/ — routing lives in CLICommand.
        do {
            // `kinhin start` parks on its own SIGINT handler (dispatchMain +
            // engine stop); every other command runs in a task the bridge
            // holds, so Ctrl-C cancels it cooperatively — an image build then
            // unwinds through its scratch-VM cleanup instead of being killed
            // mid-bake with the scratch VM left behind.
            if command == .start {
                try await dispatch(command!, args)
            } else {
                let task = Task { try await dispatch(command!, args) }
                let interruptSource = InterruptBridge.install(cancel: { task.cancel() })
                defer { interruptSource?.cancel() }
                try await task.value
            }
        } catch is CancellationError {
            printError("cancelled — in-progress work was cleaned up")
            exit(CLIExit.cancelled.rawValue)
        } catch {
            fail(error)
        }
    }

    /// The routing table's bodies, extracted so the Ctrl-C bridge can run them
    /// in a task it holds. Throws `CancellationError` when the user cancelled.
    private static func dispatch(_ command: CLICommand, _ args: [String]) async throws {
        switch command {
        case .configInit:
            if args.dropFirst().first == "validate" {
                print(try ConfigCommands.validate())
            } else {
                try ConfigCommands.configInit(args)
            }

        case .auth:
            try await AuthCommand.run(args)

        case .doctor:
            try await DoctorCommand.run(args)

        case .setupStatus:
            try await SetupStatusCommand.run(args)

        case .setupRepair:
            try await SetupRepairCommand.run(args)

        case .runtimes:
            await RuntimesCommand.run(args)

        case .imagePrepare:
            try await ImageCommand.run(args)

        case .imageDigest:
            try await ImageCommand.runDigest(args)

        case .toolchains:
            do {
                if args.dropFirst().first == "prune" {
                    await ToolchainsCommand.prune(Array(args.dropFirst()))
                } else if args.dropFirst().first == "list-images" {
                    await ToolchainsCommand.listImages()
                } else if args.dropFirst().first == "detect" {
                    ToolchainsDetectCommand.run(Array(args.dropFirst(2)))
                } else if args.dropFirst().first == "helper" {
                    ToolchainsCommand.helper(Array(args.dropFirst()))
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

        case .pipeline:
            try await PipelineCommand.run(args)

        case .logs:
            RunCommands.logs(args)

        case .daemon:
            try await RunCommands.daemon(args)

        case .cleanup:
            try await CleanupCommand.run(args)

        case .reset:
            try await ResetCommand.run(args)

        case .requeue:
            try await RunCommands.requeueQueuedJobs(args)

        case .skip:
            try await RunCommands.skipQueuedJobs(args)

        case .support:
            print(SupportLinks.summary())

        case .workflow:
            switch args.dropFirst().first {
            case "test":
                try await WorkflowTestCommand.run(Array(args.dropFirst(2)))
            case "route":
                try await WorkflowRouteCommand.run(Array(args.dropFirst(2)))
            default:
                throw CLIError("unknown workflow subcommand; available: test, route", exit: .usage)
            }

        case .version:
            print("kinhin \(kinhinVersion.current)")

        case .help:
            printHelp()

        }
    }
}
