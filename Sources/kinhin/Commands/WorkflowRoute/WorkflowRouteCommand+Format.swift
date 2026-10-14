import Foundation
import KinhinKit

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

    /// Why an uneditable job was left alone: the editor's own error text.
    static func skipReason(_ job: WorkflowJob) -> String {
        let error = WorkflowRouteEditor.EditError.cannotEdit(job.id, runsOn: job.runsOn.description)
        return error.errorDescription ?? "cannot edit"
    }

    static func dryRunSummary(
        _ options: Options, document: WorkflowDocument, planned: [PlannedEdit], uneditableJobs: [WorkflowJob],
        routeAction: RouteAction
    ) -> String {
        var lines: [String] = ["[dry-run] would edit \(document.path.lastPathComponent) → \(options.runtime.rawValue)"]
        for plan in planned where plan.changed {
            lines.append(
                "  job \(plan.jobID): \(plan.before.joined(separator: ", ")) → \(plan.after.joined(separator: ", "))")
        }
        for job in uneditableJobs {
            lines.append(
                "  job \(job.id): SKIPPED — \(skipReason(job))")
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
            "routed \(document.path.lastPathComponent) → \(options.runtime.rawValue)",
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
                "  job \(job.id): SKIPPED — \(skipReason(job))")
        }
        switch routeAction {
        case .unchanged: break
        case .added(let pattern, let runtime):
            lines.append("")
            lines.append("route: added \(pattern) → \(runtime)")
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
            "runtime": options.runtime.rawValue,
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
                payload["diff"] = plannedEdits
            }
        }
        let data = try JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted, .sortedKeys])
        return String(decoding: data, as: UTF8.self)
    }
}
