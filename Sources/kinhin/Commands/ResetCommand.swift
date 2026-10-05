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
        // Only the "everything" scope touches tart; a missing binary degrades
        // to no VMs planned (and execution says so).
        let tart: (any TartControlling)? = scope == .all ? Self.tart() : nil

        let plan = await ResetEverything.plan(scope: scope, tart: tart)
        if !confirmed {
            guard try confirm(plan: plan) else {
                print("cancelled — nothing was changed")
                return
            }
        }
        let report = try await ResetEverything.execute(plan, tart: tart)
        for line in report where line.hasPrefix("warning:") {
            warn(String(line.dropFirst("warning: ".count)))
        }
        for line in report where !line.hasPrefix("warning:") {
            print(line)
        }
        print(nextSteps(for: scope))
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

    /// tart, or nil when the binary or the config is missing (the plan then
    /// lists no VMs and execution says so). A broken config degrades to the
    /// defaults, like `cleanup` does.
    private static func tart() -> (any TartControlling)? {
        let config = (try? ConfigLoader.load()) ?? KinhinConfig.default
        return try? TartController(configuredPath: config.tartPath)
    }

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
