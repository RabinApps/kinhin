import AppIntents

struct PauseFleetIntent: AppIntent {
    static let title: LocalizedStringResource = "Pause Fleet"
    static let description = IntentDescription("Stops the fleet from starting new runner VMs. Running jobs finish.")

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let text = try await SetPausedAction.run(paused: true)
        return .result(dialog: IntentDialog(stringLiteral: text))
    }
}

struct ResumeFleetIntent: AppIntent {
    static let title: LocalizedStringResource = "Resume Fleet"
    static let description = IntentDescription("Lets a paused fleet start runner VMs again.")

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let text = try await SetPausedAction.run(paused: false)
        return .result(dialog: IntentDialog(stringLiteral: text))
    }
}

/// Shared by both intents: idempotent, and reports a no-op instead of failing.
@MainActor
enum SetPausedAction {
    static func run(paused: Bool) async throws -> String {
        let bridge = FleetIntentEnvironment.bridge
        let before = try await bridge.status()
        if before.running, before.paused != paused {
            try await bridge.setPaused(paused)
        }
        return FleetSummary.pauseResult(paused: paused, before: before)
    }
}
