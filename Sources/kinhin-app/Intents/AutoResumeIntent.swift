import AppIntents

struct EnableAutoResumeIntent: AppIntent {
    static let title: LocalizedStringResource = "Enable Auto-Resume"
    static let description = IntentDescription(
        "Lets a paused fleet resume on its own once the job queue is empty.")

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let text = try await SetAutoResumeAction.run(on: true)
        return .result(dialog: IntentDialog(stringLiteral: text))
    }
}

struct DisableAutoResumeIntent: AppIntent {
    static let title: LocalizedStringResource = "Disable Auto-Resume"
    static let description = IntentDescription(
        "Makes a pause hold until the fleet is resumed by hand.")

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let text = try await SetAutoResumeAction.run(on: false)
        return .result(dialog: IntentDialog(stringLiteral: text))
    }
}

/// Idempotent toggle of the `auto_resume` config key. The write goes through
/// the same editor and engine push as the Capacity tab's Apply, so a running
/// fleet picks the change up (restarting the engine when the config requires).
@MainActor
enum SetAutoResumeAction {
    static func run(on: Bool) async throws -> String {
        let bridge = FleetIntentEnvironment.bridge
        let current = try await bridge.autoResumeEnabled()
        if current == on {
            return FleetSummary.autoResumeResult(on: on, outcome: .alreadyThere)
        }
        try await bridge.setAutoResume(on)
        return FleetSummary.autoResumeResult(on: on, outcome: .done)
    }
}
