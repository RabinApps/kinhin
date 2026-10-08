import Foundation
import KinhinKit

/// What bare `kinhin` prints: where the setup stands, whether a daemon is
/// running, and the single next step — instead of the full help screen
/// (`kinhin help` still prints that). Read-only: it probes, never writes.
enum BareStatus {
    struct Step: Equatable {
        /// The command to run (or the thing to do).
        var command: String
        /// Why: the failing check, or what the command does.
        var reason: String
    }

    /// The one thing to do next: the first failing check's fix, else start the
    /// fleet, else look at it.
    static func nextStep(setup: SetupStatus, daemonRunning: Bool) -> Step {
        if let failing = setup.checks.first(where: { !$0.ok }) {
            let command =
                failing.action.flatMap(SetupStatusCommand.cliCommand(for:)) ?? "kinhin doctor"
            return Step(command: command, reason: "\(failing.title): \(failing.detail)")
        }
        if !setup.ready {
            return Step(command: "kinhin setup status", reason: "something outside the checklist needs attention")
        }
        if daemonRunning {
            return Step(command: "kinhin status", reason: "the fleet is running")
        }
        return Step(command: "kinhin start", reason: "everything is ready; start the fleet (Ctrl-C to stop)")
    }

    static func render(setup: SetupStatus, daemonRunning: Bool, version: String) -> String {
        let passing = setup.checks.filter(\.ok).count
        let setupLine =
            setup.ready
            ? "ready (\(passing) of \(setup.checks.count) checks)"
            : "\(setup.checks.count - passing) of \(setup.checks.count) checks need attention"
        let step = nextStep(setup: setup, daemonRunning: daemonRunning)
        var lines = [
            "kinhin \(version) — autoscaling CI runners on your Mac",
            "",
            "  setup    \(setupLine)",
            "  daemon   \(daemonRunning ? "running" : "not running")",
            "",
            "next: \(step.command)",
        ]
        lines += HelpRenderer.wrap(step.reason, width: HelpRenderer.columns - 6, indent: "").map { "      " + $0 }
        lines += [
            "",
            "`kinhin help` lists every command; `kinhin <command> --help` shows its options.",
        ]
        return lines.joined(separator: "\n")
    }

    static func run() async {
        let setup = await SetupStatusComputer().compute()
        print(render(setup: setup, daemonRunning: RPCClient.isDaemonAlive(), version: kinhinVersion.current))
    }
}
