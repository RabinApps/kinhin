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

    /// Parse the CLI args after `kinhin workflow route`. Positionals are
    /// `<FILE|workflow name>` and the target runtime, in either order (the
    /// runtime is the only argument `RuntimeID` accepts, so it is unambiguous
    /// when both are given; one lone positional can only be the runtime —
    /// there would be no workflow to route).
    static func parse(_ args: [String]) throws -> Options {
        var opt = Options()
        var positionals: [String] = []
        var index = 0
        while index < args.count {
            let arg = args[index]
            switch arg {
            case "--dry-run": opt.dryRun = true
            case "--json": opt.json = true
            case "--consent": opt.consent = true
            case "--help", "-h":
                throw CLIError(help, exit: .usage)
            case "--job":
                index += 1
                guard index < args.count else {
                    throw WorkflowRouteCLIError.usage("--job needs a job name")
                }
                opt.job = args[index]
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
                positionals.isEmpty
                    ? "missing target runtime — expected one of: tart, appleContainer, docker, host"
                    : "missing target runtime after '\(positionals.last!)' — expected one of: tart, appleContainer, docker, host"
            )
        }
        opt.runtime = runtime

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
        do { originalYAML = try String(contentsOf: file, encoding: .utf8) }
        catch { throw WorkflowRouteCLIError.usage("cannot read \(file.path) for the planned diff") }
        let plannedEdits = plannedEditsText(planned: planned, originalYAML: originalYAML)
        let plannedEditsText = plannedEdits

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
                    options, document: document, planned: planned, uneditableJobs: uneditableJobs,                        routeAction: routeAction, dryRun: false,
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

// MARK: - File resolution

extension WorkflowRouteCommand {
    static func resolveFile(_ options: Options) throws -> URL {
        if let file = options.file {
            guard FileManager.default.fileExists(atPath: file.path) else {
                throw WorkflowRouteCLIError.usage("no workflow file at \(file.path)")
            }
            return file
        }
        let cwd = FileManager.default.currentDirectoryPath
        let dir = URL(fileURLWithPath: cwd)
        guard let name = options.workflowName else {
            throw WorkflowRouteCLIError.usage(
                "no workflow file given — pass a path or a workflow name; run `kinhin workflow test --list` to see names"
            )
        }
        let workflowsDir = dir.appendingPathComponent(".github/workflows")
        guard FileManager.default.fileExists(atPath: workflowsDir.path) else {
            throw WorkflowRouteCLIError.usage("no .github/workflows/ in \(cwd) — run from a repo checkout")
        }
        let candidates = try FileManager.default
            .contentsOfDirectory(at: workflowsDir, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "yml" || $0.pathExtension == "yaml" }
        let matches = candidates.filter { candidate in
            (try? loadWorkflow(at: candidate))?.name.caseInsensitiveCompare(name) == .orderedSame
        }
        guard matches.count == 1 else {
            if matches.isEmpty {
                throw WorkflowRouteCLIError.usage("no workflow named '\(name)' in \(workflowsDir.path)")
            }
            let names = matches.map(\.lastPathComponent).sorted().joined(separator: ", ")
            throw WorkflowRouteCLIError.usage(
                "more than one workflow named '\(name)': \(names) — pass a file path instead")
        }
        return matches[0]
    }

    private static func loadWorkflow(at url: URL) throws -> WorkflowDocument {
        let data = try Data(contentsOf: url)
        return try parseWorkflow(data, at: url)
    }
}

// MARK: - Job scoping

extension WorkflowRouteCommand {
    static func resolveJobIDs(_ options: Options, in document: WorkflowDocument) throws -> Set<String> {
        guard !document.jobs.isEmpty else {
            throw WorkflowRouteCLIError.usage("workflow '\(document.name)' has no jobs — nothing to route")
        }
        if let job = options.job {
            guard
                let found = document.jobs.first(where: {
                    $0.id.caseInsensitiveCompare(job) == .orderedSame
                        || $0.name.caseInsensitiveCompare(job) == .orderedSame
                })
            else {
                let known = document.jobs.map { "\($0.id) (\($0.name))" }.joined(separator: ", ")
                throw WorkflowRouteCLIError.usage("no job named '\(job)'; known jobs: \(known)")
            }
            return [found.id]
        }
        return Set(document.jobs.map(\.id))
    }
}

// MARK: - Route reconciliation

extension WorkflowRouteCommand {
    /// If precedence means the label edit alone wouldn't carry every selected
    /// job to `targetRuntime`, write a `scope@Workflow` route through the
    /// validated editor (comments preserved, whole-file validation gates the
    /// write). Returns what was done; with `dryRun` the decision is reported
    /// but nothing is written.
    static func reconcileRouteIfNeeded(
        document: WorkflowDocument, targetRuntime: RuntimeID, config: KinhinConfig,
        scope: String, jobs: [WorkflowJob], configURL: URL, dryRun: Bool
    ) throws -> RouteAction {
        let rc: KinhinConfig.RuntimeConfig?
        do {
            rc = try RuntimesConfigEditor.parsed(from: try String(contentsOf: configURL, encoding: .utf8))
        } catch {
            throw CLIError(
                "config.yaml has an invalid runtimes: section — fix it, or run: kinhin config validate",
                exit: .config)
        }
        let pattern = "\(scope)@\(document.name)"
        let target = targetRuntime.rawValue

        let action: RouteAction
        if let existing = rc?.routes.first(where: { $0.pattern == pattern }) {
            guard existing.runtime != target else { return .unchanged }
            action = .replaced(existing: pattern, runtime: target)
        } else if routeNeeded(rc: rc, config: config, targetRuntime: targetRuntime, scope: scope, jobs: jobs) {
            // The pattern must be owner/repo@Workflow to match the jobs the
            // forge queues; an org-wide scope can't name the repo.
            guard scope.contains("/") else {
                throw WorkflowRouteCLIError.usage(
                    "routing to \(target) needs a config route, but scope '\(scope)' is org-wide — "
                        + "add one for this workflow's repo first: "
                        + "kinhin runtimes route add <owner/repo>@\(document.name) \(target), then re-run")
            }
            action = .added(pattern: pattern, runtime: target)
        } else {
            return .unchanged
        }

        if !dryRun {
            var updated = rc ?? KinhinConfig.RuntimeConfig()
            if rc == nil {
                // Creating the section (host on a single-pool fleet): keep the
                // default the fleet actually serves on, so unrouted jobs
                // don't change pools as a side effect.
                updated.defaultRuntime = effectivePrimary(of: config).rawValue
            }
            if case .replaced = action {
                updated.routes.removeAll { $0.pattern == pattern }
            }
            updated.routes.append(
                KinhinConfig.RuntimeConfig.Route(
                    pattern: pattern, runtime: target, consent: targetRuntime == .host ? true : nil))
            try applyRoute(updated, to: configURL)
        }
        return action
    }

    /// True when the `runs-on:` edit alone would not carry every selected job
    /// to the target pool. Precedence: workflow route → repo route → label
    /// marker → default.
    private static func routeNeeded(
        rc: KinhinConfig.RuntimeConfig?, config: KinhinConfig, targetRuntime: RuntimeID,
        scope: String, jobs: [WorkflowJob]
    ) -> Bool {
        guard let rc else {
            // Single-pool fleet: the pool pre-flight proved the target is the
            // default — except host, which the engine serves only through a
            // route (its pool pre-flight answered as if this command's own
            // consented route exists).
            return targetRuntime == .host
        }
        let target = targetRuntime.rawValue
        // A repo route (no @Workflow) for this scope outranks the marker.
        if let repoRoute = rc.routes.first(where: { !$0.pattern.contains("@") && $0.pattern == scope }) {
            return repoRoute.runtime != target
        }
        let defaultRuntime = RuntimeID(rawValue: rc.defaultRuntime) ?? .tart
        if defaultRuntime == targetRuntime { return false }
        guard let marker = WorkflowRouteEditor.marker(for: targetRuntime) else {
            // tart carries no label marker: only a route can take it off the default.
            return true
        }
        // The marker carries any job that has it or will get it (the editor
        // appends it); jobs the editor refused still need the route.
        return jobs.contains { !WorkflowRouteEditor.canEdit($0) && !WorkflowRouteEditor.hasMarker($0, marker: marker) }
    }

    /// The default a fleet *without* a `runtimes:` section actually serves
    /// on — the same primary-runtime rule `RuntimeConfigModel` applies.
    private static func effectivePrimary(of config: KinhinConfig) -> RuntimeID {
        if config.container != nil { return .appleContainer }
        if config.docker != nil { return .docker }
        return .tart
    }

    /// A live daemon picks route edits up without a restart.
    private static func applyRoute(_ updated: KinhinConfig.RuntimeConfig, to configURL: URL) throws {
        do {
            try RuntimesConfigEditor.apply(updated, to: configURL)
        } catch let error as ConfigEditError {
            throw CLIError(error.errorDescription ?? "config update rejected", exit: .config)
        } catch {
            throw CLIError("config update failed: \(error.localizedDescription)", exit: .config)
        }
    }
}

// MARK: - Output

extension WorkflowRouteCommand {
    struct PlannedEdit: Sendable {
        let jobID: String
        let before: [String]
        let after: [String]
        let wrote: Bool
        var changed: Bool { before != after }
    }

    enum RouteAction: Sendable, Equatable {
        case unchanged
        case added(pattern: String, runtime: String)
        case replaced(existing: String, runtime: String)
    }

    static func dryRunSummary(
        _ options: Options, document: WorkflowDocument, planned: [PlannedEdit], uneditableJobs: [WorkflowJob],
        routeAction: RouteAction
    ) -> String {
        var lines: [String] = ["[dry-run] would edit \(document.path.lastPathComponent) → \(options.runtime!.rawValue)"]
        for plan in planned where plan.changed {
            lines.append(
                "  job \(plan.jobID): \(plan.before.joined(separator: ", ")) → \(plan.after.joined(separator: ", "))")
        }
        for job in uneditableJobs {
            lines.append(
                "  job \(job.id): SKIPPED — \(WorkflowRouteEditor.EditError.cannotEdit(job.id, runsOn: job.runsOn.description).errorDescription!)"
            )
        }
        switch routeAction {
        case .unchanged: break
        case .added(let pattern, let runtime):
            lines.append("")
            lines.append("[dry-run] would add config route: \(pattern) → \(runtime)")
        case .replaced(let existing, let runtime):
            lines.append("")
            lines.append("[dry-run] would replace config route: \(existing) → \(runtime)")
        }
        return lines.joined(separator: "\n")
    }

    /// Why the pool check failed and how to fix it — per runtime, with the
    /// Linux comparison in the docs so a wrong guess lands on the trade-offs.
    static func prerequisiteHint(for runtime: RuntimeID, in config: KinhinConfig) -> String {
        switch runtime {
        case .appleContainer:
            if config.container == nil {
                return "add a container: section and prepare it: kinhin image prepare --container; "
                    + "see docs/runtimes.md#choosing-a-linux-runtime"
            } else {
                return "prepare the container image: kinhin image prepare --container"
            }
        case .docker:
            if config.docker == nil {
                return "add a docker: section: kinhin image prepare --docker; "
                    + "see docs/runtimes.md#choosing-a-linux-runtime"
            } else {
                return "prepare the docker image: kinhin image prepare --docker"
            }
        case .host:
            if !config.hostRoutesConfigured {
                return "host execution joins the fleet only through a consented route — "
                    + "see docs/runtimes.md#host-mode-run-jobs-directly-on-your-mac"
            } else {
                return "install the host agent: kinhin setup repair host-agent"
            }
        case .tart:
            // The tart pool exists whenever a runtimes: section does; without
            // one the fleet is single-pool on its primary runtime.
            return "the fleet is single-pool on its default runtime — create the runtimes: section first: "
                + "kinhin runtimes route add \(config.repo) tart"
        }
    }

    static func humanSummary(
        _ options: Options, document: WorkflowDocument, planned: [PlannedEdit], uneditableJobs: [WorkflowJob],
        routeAction: RouteAction, file: URL
    ) -> String {
        var lines: [String] = [
            "routed \(document.path.lastPathComponent) → \(options.runtime!.rawValue)",
            "",
            "edits:",
        ]
        for plan in planned {
            let arrow = plan.changed ? "→" : "(unchanged)"
            lines.append(
                "  job \(plan.jobID): \(plan.before.joined(separator: ", ")) \(arrow) \(plan.after.joined(separator: ", "))"
            )
        }
        for job in uneditableJobs {
            lines.append(
                "  job \(job.id): SKIPPED — \(WorkflowRouteEditor.EditError.cannotEdit(job.id, runsOn: job.runsOn.description).errorDescription!)"
            )
        }
        switch routeAction {
        case .unchanged: break
        case .added(let pattern, let runtime):
            lines.append("")
            lines.append(                "route: added \(pattern) → \(runtime)")
        case .replaced(let existing, let runtime):
            lines.append("")
            lines.append("route: replaced \(existing) → \(runtime)")
        }
        lines.append("")
        lines.append("edited \(file.lastPathComponent); run `git diff \(file.path)` to review")
        return lines.joined(separator: "\n")
    }

    static func jsonReport(
        _ options: Options, document: WorkflowDocument, planned: [PlannedEdit], uneditableJobs: [WorkflowJob],
        routeAction: RouteAction, dryRun: Bool, plannedEdits: String = ""
    ) throws -> String {
        let jobs: [[String: Any]] =
            planned.map { plan in
                ["id": plan.jobID, "before": plan.before, "after": plan.after, "wrote": dryRun ? false : plan.wrote]
            }
            + uneditableJobs.map { job in
                [
                    "id": job.id, "before": job.runsOn.description, "after": job.runsOn.description, "wrote": false,
                    "reason": "cannot edit",
                ]
            }
        var payload: [String: Any] = [
            "file": document.path.lastPathComponent,
            "workflow": document.name,
            "runtime": options.runtime!.rawValue,
            "dryRun": dryRun,
            "jobs": jobs,
        ]
        switch routeAction {
        case .unchanged:
            payload["route"] = ["action": "unchanged"]
        case .added(let pattern, let runtime):
            payload["route"] = ["action": "added", "pattern": pattern, "runtime": runtime]
        case .replaced(let existing, let runtime):
            payload["route"] = ["action": "replaced", "previous": existing, "runtime": runtime]
        }
        if dryRun {
            if !plannedEdits.isEmpty {
                payload["diff"] = plannedEdits.joined(separator: "\n")
            }
        }
        let data = try JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted, .sortedKeys])
        return String(decoding: data, as: UTF8.self)
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
