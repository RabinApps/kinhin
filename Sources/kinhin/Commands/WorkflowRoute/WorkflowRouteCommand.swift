import Foundation
import KinhinKit

// MARK: - `kinhin workflow route <file|name> <runtime> [--job NAME] [--dry-run] [--json] [--consent]`

/// Usage failures of `workflow route`, carried as the CLI's standard error so
/// the process exits 2 like every other bad command line.
enum WorkflowRouteCLIError {
    static func usage(_ message: String) -> CLIError { CLIError(message, exit: .usage) }
}

enum WorkflowRouteCommand {
    struct Options: Sendable {
        var file: URL?
        var workflowName: String?
        var runtime: RuntimeID?
        var job: String?
        var dryRun = false
        var json = false
        var consent = false
    }
    static func run(_ args: [String], configURL: URL = Paths.config, notifyDaemon: Bool = true) async throws {
        let options = try parse(args)
        guard FileManager.default.fileExists(atPath: configURL.path) else {
            throw CLIError("no kinhin config at \(configURL.path) — run: kinhin config init", exit: .config)
        }
        let config = try ConfigLoader.load(from: configURL)
        let file = try resolveFile(options)
        let document = try loadWorkflow(at: file)
        let runtime = options.runtime!  // parse guarantees it

        // 1. The target pool must exist — checked against the exact table the
        //    engine builds, so a wrong guess is told how to set the runtime up.
        guard let poolLabels = RuntimeConfigModel.poolLabels(for: runtime, config: config) else {
            throw WorkflowRouteCLIError.usage(
                "target runtime '\(runtime.rawValue)' has no configured pool — \(prerequisiteHint(for: runtime, in: config))"
            )
        }

        // 2. Scope + forge gate: label targeting only. GitLab / Buildkite /
        //    Azure queue by tags, queues or demands — those route through
        //    config (the pre-flight says so and points at `runtimes route add`).
        let scope = config.repo.isEmpty ? config.allAccounts.first?.scope ?? "" : config.repo
        guard !scope.isEmpty else {
            throw WorkflowRouteCLIError.usage(
                "no forge scope configured — add an account first: kinhin auth add NAME --github --scope owner/repo")
        }
        if let problem = WorkflowRoutePreFlight.forRepository(scope, config: config) {
            throw CLIError(problem.description, exit: .usage)
        }

        // 3. Scope the jobs.
        let jobIDs = try resolveJobIDs(options, in: document)
        let selected = document.jobs.filter { jobIDs.contains($0.id) }
        let editableJobs = selected.filter(WorkflowRouteEditor.canEdit)
        let uneditableJobs = selected.filter { !WorkflowRouteEditor.canEdit($0) }

        // 4. What the editor will do to each editable job.
        let planned: [PlannedEdit] = try editableJobs.map { job in
            let current = try WorkflowRouteEditor.labels(job)
            let after = WorkflowRouteEditor.editJobLabels(current: current, runtime: runtime, poolLabels: poolLabels)
            return PlannedEdit(jobID: job.id, before: current, after: after, wrote: after != current)
        }

        let originalYAML: String
        do { originalYAML = try String(contentsOf: file, encoding: .utf8) } catch {
            throw WorkflowRouteCLIError.usage("cannot read \(file.path) for the planned diff")
        }

        /// Apply the planned label edits to a copy of the original YAML and return
        /// the result — used for the dry-run "diff of planned runs-on: edits" text
        /// and the JSON `diff` field. Only the jobs whose plan changed are applied;
        /// everything else (comments, formatting, other keys) is preserved byte-for-byte.
        func editedYAML(for planned: [PlannedEdit], originalYAML: String) -> String {
            var edited = originalYAML
            for plan in planned where plan.changed {
                edited = try! WorkflowRouteEditor.applyLabelEdit(jobID: plan.jobID, labels: plan.after, in: edited)
            }
            return edited
        }
        let plannedEditsText = editedYAML(for: planned, originalYAML: originalYAML)

        // 5. The config route first, when routing precedence needs one: a
        //    route that lands first still carries the jobs (it outranks
        //    labels), while a workflow edited first could be left unrouted if
        //    this write failed.
        let routeAction = try reconcileRouteIfNeeded(
            document: document, targetRuntime: runtime, config: config,
            scope: scope, jobs: selected, configURL: configURL, dryRun: options.dryRun)

        if options.dryRun {
            if options.json {
                print(
                    try jsonReport(
                        options, document: document, planned: planned, uneditableJobs: uneditableJobs,
                        routeAction: routeAction, dryRun: true,
                        plannedEdits: plannedEditsText))
            } else {
                print(
                    dryRunSummary(
                        options, document: document, planned: planned, uneditableJobs: uneditableJobs,
                        routeAction: routeAction))
                if !plannedEditsText.isEmpty {
                    print("")
                    print("diff of planned runs-on: edits:")
                    print(plannedEditsText)
                }
            }
            return
        }

        // 6. The workflow itself: comment-preserving line surgery, with the
        //    whole edited document re-parsed before a single byte is written.
        if planned.contains(where: \.changed) {
            var newYAML = try String(contentsOf: file, encoding: .utf8)
            for plan in planned where plan.changed {
                newYAML = try WorkflowRouteEditor.applyLabelEdit(jobID: plan.jobID, labels: plan.after, in: newYAML)
            }
            _ = try parseWorkflow(Data(newYAML.utf8), at: file)  // must still parse
            try newYAML.write(to: file, atomically: true, encoding: .utf8)
        }

        if options.json {
            print(
                try jsonReport(
                    options, document: document, planned: planned, uneditableJobs: uneditableJobs,
                    routeAction: routeAction, dryRun: false,
                    plannedEdits: plannedEditsText))
        } else {
            print(
                humanSummary(
                    options, document: document, planned: planned, uneditableJobs: uneditableJobs,
                    routeAction: routeAction, file: file))
        }

        // 7. A live daemon picks the new route table up without a restart.
        guard notifyDaemon, routeAction != .unchanged, RPCClient.isDaemonAlive() else { return }
        do {
            try RPCClient().reloadConfig()
            print("  daemon notified — routing reloaded")
        } catch {
            print("  warning: daemon did not accept the reload — \(error.localizedDescription)")
        }
    }
}
