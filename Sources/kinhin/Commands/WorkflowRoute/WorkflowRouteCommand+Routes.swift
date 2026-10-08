import Foundation
import KinhinKit

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
