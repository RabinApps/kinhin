import Foundation
import KinhinKit

// MARK: - Argument parsing and help

extension WorkflowRouteCommand {
    /// Parse the CLI args after `kinhin workflow route`. Positionals are
    /// `<FILE|workflow name>` and the target runtime, in either order (the
    /// runtime is the only argument `RuntimeID` accepts, so it is unambiguous
    /// when both are given; one lone positional can only be the runtime —
    /// there would be no workflow to route).
    static func parse(_ args: [String]) throws -> Options {
        var job: String?
        var dryRun = false
        var json = false
        var consent = false
        var positionals: [String] = []
        var index = 0
        while index < args.count {
            let arg = args[index]
            switch arg {
            case "--dry-run": dryRun = true
            case "--json": json = true
            case "--consent": consent = true
            case "--help", "-h":
                throw CLIError(help, exit: .usage)
            case "--job":
                index += 1
                guard index < args.count else {
                    throw WorkflowRouteCLIError.usage("--job needs a job name")
                }
                job = args[index]
            case let v where v.hasPrefix("--"):
                throw WorkflowRouteCLIError.usage("unknown option: \(v)")
            default:
                positionals.append(arg)
            }
            index += 1
        }

        // The runtime is the only positional `RuntimeID` accepts: prefer the
        // last token (the documented order), else a single unambiguous match
        // (`route ci.yml appleContainer extra`).
        let runtimeCandidates = positionals.compactMap { RuntimeID(rawValue: $0) }
        let chosenRuntime: RuntimeID?
        if let last = positionals.last, let runtime = RuntimeID(rawValue: last) {
            chosenRuntime = runtime
            positionals.removeLast()
        } else if runtimeCandidates.count == 1, let only = runtimeCandidates.first {
            chosenRuntime = only
            positionals.removeAll { RuntimeID(rawValue: $0) != nil }
        } else {
            chosenRuntime = nil
        }
        guard let runtime = chosenRuntime else {
            throw WorkflowRouteCLIError.usage(
                positionals.last.map {
                    "missing target runtime after '\($0)' — expected one of: tart, appleContainer, docker, host"
                } ?? "missing target runtime — expected one of: tart, appleContainer, docker, host"
            )
        }
        var opt = Options(runtime: runtime, job: job, dryRun: dryRun, json: json, consent: consent)

        switch positionals.count {
        case 0:
            throw WorkflowRouteCLIError.usage(
                "no workflow file given — pass a path or a workflow name; run `kinhin workflow test --list` to see names"
            )
        case 1:
            let value = positionals[0]
            let candidate = URL(fileURLWithPath: value)
            if candidate.pathExtension == "yml" || candidate.pathExtension == "yaml" {
                opt.file = candidate
            } else {
                opt.workflowName = value
            }
        default:
            let extra = positionals.dropFirst().joined(separator: ", ")
            throw WorkflowRouteCLIError.usage("unexpected: \(extra)")
        }

        // Consent gates host everywhere: config validation, `runtimes route
        // add`, the app's Add Route sheet — and here, before any edit.
        if opt.runtime == .host, !opt.consent {
            throw WorkflowRouteCLIError.usage(
                "host routes run repo code directly on your Mac, unisolated. Review the risk, then re-run with --consent"
            )
        }
        if opt.consent, opt.runtime != .host {
            throw WorkflowRouteCLIError.usage("--consent applies to host routes only")
        }
        return opt
    }

    static let help = """
        usage: kinhin workflow route <FILE|workflow name> <tart|appleContainer|docker|host> \\
                [--job NAME] [--dry-run] [--json] [--consent]

        Route a workflow's jobs to a kinhin runtime: edits the workflow's runs-on: labels
        (comment-preserving; ${{ }} expressions, group mappings and reusable-workflow jobs
        are refused) and, when routing precedence needs it, adds an owner/repo@Workflow
        route to config.yaml — a running daemon reloads it live.
          --job NAME   Route one job instead of every job in the workflow
          --dry-run    Print what would change; write nothing
          --json       Machine-readable report
          --consent    Required for host (jobs run unisolated on this Mac)
        """
}
