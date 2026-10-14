import Foundation
import KinhinKit

/// `kinhin reset` — wipes kinhin's local state by scope, irreversibly:
/// config & credentials, the daemon install, or everything (VMs, images,
/// cache, logs included). The plan is shown, then confirmed twice — a y/N and
/// a typed `reset` — unless `--yes` skips both prompts for scripts. The word
/// is the same for every scope: the plan listing already differs per scope.
enum ResetCommand {
    /// The word confirmation 2 requires, exactly.
    static let confirmWord = "reset"

    static func run(_ args: [String]) async throws {
        if hasFlag("--help", in: args) || hasFlag("-h", in: args) {
            printHelp()
            return
        }
        let confirmed = hasFlag("--yes", in: args)
        let scope = try resolveScope(args: args, interactive: isInteractive())
        // The plan reads the config once and builds tart from its tart_path;
        // a broken config is flagged in the plan (and warned about below)
        // instead of silently falling back to the default tart path.
        let plan = try await ResetEverything.plan(scope: scope)
        if !confirmed {
            guard try confirm(plan: plan) else {
                print("cancelled — nothing was changed")
                return
            }
        }
        let report = try await ResetEverything.execute(plan)
        for line in warnings(plan: plan, report: report) { warn(line) }
        for line in report.completed { print(line) }
        print(nextSteps(for: scope))
        if !report.isComplete {
            printError(leftBehindSummary(report))
        }
        ExitRule.finish(healthy: report.isComplete)
    }

    // MARK: - Output

    /// The stderr lines after a reset: the unreadable config (its defaults
    /// stood in for the tart path and image names), then everything that was
    /// left behind.
    static func warnings(plan: ResetPlan, report: ResetReport) -> [String] {
        var lines: [String] = []
        if plan.configBroken, plan.scope == .all {
            let reason = plan.configError.map { " (\($0))" } ?? ""
            lines.append("the config could not be read\(reason); the tart path and image names came from the defaults")
        }
        return lines + report.leftBehind
    }

    /// The closing stderr line of a reset that left something behind; the
    /// exit code is then "needs attention" (1).
    static func leftBehindSummary(_ report: ResetReport) -> String {
        "kinhin reset finished, but \(report.leftBehind.count) item(s) were left behind; see the warnings above"
    }

    // MARK: - Scope

    /// The scope from `--scope config|daemon|all`, or the interactive menu.
    /// A non-interactive run without `--scope` throws usage instead of
    /// hanging on a prompt it could never read. Throws (rather than exiting
    /// through `fail`) so tests can exercise it hermetically; the dispatcher
    /// turns the error into the exit code.
    static func resolveScope(args: [String], interactive: Bool) throws -> ResetScope {
        if let raw = flag("--scope", in: args) {
            guard let scope = ResetScope(rawValue: raw) else {
                throw CLIError(
                    "--scope must be one of: \(ResetScope.allCases.map(\.rawValue).joined(separator: ", "))",
                    exit: .usage)
            }
            return scope
        }
        guard interactive else {
            throw CLIError(
                "kinhin reset needs --scope config|daemon|all when stdin is not a terminal (add --yes to run without prompts)",
                exit: .usage)
        }
        return try pickScope()
    }

    /// The numbered scope menu (interactive runs without `--scope`).
    private static func pickScope() throws -> ResetScope {
        print("What should kinhin reset?")
        for (index, scope) in ResetScope.allCases.enumerated() {
            print("  \(index + 1). \(scope.label) — \(scope.summary)")
        }
        print("Choice [1-\(ResetScope.allCases.count)]: ", terminator: "")
        guard let line = readLine()?.trimmingCharacters(in: .whitespaces), let pick = Int(line),
            ResetScope.allCases.indices.contains(pick - 1)
        else {
            throw CLIError("pick a number between 1 and \(ResetScope.allCases.count)", exit: .usage)
        }
        return ResetScope.allCases[pick - 1]
    }

    // MARK: - Confirmations

    /// Confirmation 1: the exact plan, then y/N. Confirmation 2: type `reset`.
    /// Anything other than the word — or anything but y/yes — cancels.
    static func confirm(plan: ResetPlan) throws -> Bool {
        print(plan.describe())
        print("")
        print("Proceed? This cannot be undone [y/N]: ", terminator: "")
        guard
            let answer = readLine()?.trimmingCharacters(in: .whitespaces).lowercased(),
            answer == "y" || answer == "yes"
        else { return false }
        print("Type \(confirmWord) to erase the above (anything else cancels): ", terminator: "")
        guard readLine()?.trimmingCharacters(in: .whitespaces) == confirmWord else { return false }
        return true
    }

    // MARK: - Collaborators

    private static func isInteractive() -> Bool {
        isatty(STDIN_FILENO) == 1
    }

    /// What to do after the reset, per scope.
    static func nextSteps(for scope: ResetScope) -> String {
        switch scope {
        case .config, .all:
            return
                "kinhin has been reset — the next command re-creates a starter config; store a token with `kinhin auth set`"
        case .daemon:
            return "daemon removed — `kinhin daemon install` reinstalls it"
        }
    }
}
