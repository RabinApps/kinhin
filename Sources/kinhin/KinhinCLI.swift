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

        // Bare `kinhin`: where setup stands and the next step. `kinhin help`
        // prints the full screen.
        if args.isEmpty {
            await BareStatus.run()
            return
        }

        let invocation: Invocation
        do {
            invocation = try CommandResolver.resolve(args)
        } catch {
            ErrorReporter.useJSON(args.contains("--json"))
            fail(error)
        }
        ErrorReporter.useJSON(invocation.json)
        let command = invocation.command

        if invocation.wantsHelp {
            print(HelpRenderer.page(for: invocation.helpSpec, path: invocation.helpPath))
            return
        }

        if CLICommand.shouldAutoCreateConfig(command, args: invocation.args) {
            noteAutoCreatedConfigIfMissing()
        }

        // Dispatch. Bodies live in Commands/ — routing lives in CLICommand.
        do {
            // `kinhin start` parks on its own SIGINT handler (dispatchMain +
            // engine stop); `kinhin mcp` reads stdin until EOF and needs the
            // default SIGINT disposition (a cooperative cancel cannot
            // interrupt a blocked stdin read). Every other command runs in a
            // task the bridge holds, so Ctrl-C cancels it cooperatively — an
            // image build then unwinds through its scratch-VM cleanup instead
            // of being killed mid-bake with the scratch VM left behind.
            if command == .start || command == .mcp {
                try await dispatch(invocation)
            } else {
                let task = Task { try await dispatch(invocation) }
                let interruptSource = InterruptBridge.install(cancel: { task.cancel() })
                defer { interruptSource?.cancel() }
                try await task.value
            }
        } catch is CancellationError {
            if ErrorReporter.isJSON {
                ErrorReporter.report("cancelled — in-progress work was cleaned up", code: .cancelled)
            } else {
                printError("cancelled — in-progress work was cleaned up")
            }
            exit(CLIExit.cancelled.rawValue)
        } catch {
            fail(error)
        }
    }

    /// The routing table's bodies, extracted so the Ctrl-C bridge can run them
    /// in a task it holds. Throws `CancellationError` when the user cancelled.
    private static func dispatch(_ invocation: Invocation) async throws {
        let args = invocation.args
        let rest = invocation.rest
        switch invocation.command {
        case .configInit:
            if invocation.subcommand == "validate" {
                try ConfigCommands.runValidate(rest)
            } else if invocation.subcommand == "reload" {
                try ConfigCommands.reload()
            } else if invocation.subcommand == "migrate" {
                try ConfigCommands.migrate(rest)
            } else if invocation.subcommand == "export" {
                try ConfigCommands.export(rest)
            } else if invocation.subcommand == "import" {
                try ConfigCommands.importConfig(rest)
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

        case .imageList:
            try await ImageListCommand.run(rest)

        case .imageDelete:
            try await ImageDeleteCommand.run(rest)

        case .imagePrune:
            try await ImagePruneCommand.run(rest)

        case .imageDigest:
            try await ImageCommand.runDigest(rest)

        case .toolchains:
            switch invocation.subcommand {
            case "prune": await ToolchainsCommand.prune(rest)
            case "list-images": await ToolchainsCommand.listImages()
            case "detect": ToolchainsDetectCommand.run(rest)
            case "helper": ToolchainsCommand.helper(rest)
            default: await ToolchainsCommand.run(args)
            }

        case .mobile:
            switch invocation.subcommand {
            case "init": MobileCommand.run(rest)
            default:
                fail(
                    "usage: kinhin mobile init [DIR] [--framework NAME] [--ci SYSTEM] [--force] [--dry-run]",
                    exit: .usage)
            }

        case .start:
            try await RunCommands.start(args)

        case .stop:
            try await RunCommands.stop(args)

        case .pause:
            try await RunCommands.pauseResume("pause", args: args)

        case .resume:
            try await RunCommands.pauseResume("resume", args: args)

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

        case .bench:
            try await BenchCommand.run(rest)

        case .reset:
            try await ResetCommand.run(args)

        case .requeue:
            try await RunCommands.requeueQueuedJobs(args)

        case .skip:
            try await RunCommands.skipQueuedJobs(args)

        case .heal:
            try await HealCommand.run(args, subcommand: invocation.subcommand)

        case .support:
            print(SupportLinks.summary())

        case .issue:
            try IssueCommand.run(args)

        case .mcp:
            try await MCPCommand.run(args)

        case .workflow:
            switch invocation.subcommand {
            case "test": try await WorkflowTestCommand.run(rest)
            default: try await WorkflowRouteCommand.run(rest)
            }

        case .video:
            try await VideoCommand.run(path: invocation.path, rest)

        case .version:
            print("kinhin \(kinhinVersion.current)")

        case .help:
            print(helpText(for: rest))
        }
    }
}
