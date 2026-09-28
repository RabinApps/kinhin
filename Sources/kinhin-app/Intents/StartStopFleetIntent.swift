import AppIntents

struct StartFleetIntent: AppIntent {
    static let title: LocalizedStringResource = "Start Fleet"
    static let description = IntentDescription("Starts the runner fleet so queued jobs can begin.")

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let text = try await StartStopFleetAction.run(start: true)
        return .result(dialog: IntentDialog(stringLiteral: text))
    }
}

struct StopFleetIntent: AppIntent {
    static let title: LocalizedStringResource = "Stop Fleet"
    static let description = IntentDescription("Stops the runner fleet. Running jobs finish before the VMs go down.")

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let text = try await StartStopFleetAction.run(start: false)
        return .result(dialog: IntentDialog(stringLiteral: text))
    }
}

/// Shared by both intents: idempotent, and reports a no-op instead of failing.
@MainActor
enum StartStopFleetAction {
    static func run(start: Bool) async throws -> String {
        let bridge = FleetIntentEnvironment.bridge
        let before = try await bridge.status()
        // Already in the wanted state: starting a running fleet, stopping a
        // stopped one — report, don't act.
        if before.running == start {
            return FleetSummary.startStopResult(start: start, outcome: .alreadyThere)
        }
        if start { try await bridge.startFleet() } else { try await bridge.stopFleet() }
        let after = try await bridge.status()
        return FleetSummary.startStopResult(start: start, outcome: after.running == start ? .done : .uncertain)
    }
}
