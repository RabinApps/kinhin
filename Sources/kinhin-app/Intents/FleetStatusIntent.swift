import AppIntents

struct FleetStatusIntent: AppIntent {
    static let title: LocalizedStringResource = "Fleet Status"
    static let description = IntentDescription(
        "Reports whether the runner fleet is running, how busy it is and how many jobs are queued.")

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<String> & ProvidesDialog {
        let text = FleetSummary.status(try await FleetIntentEnvironment.bridge.status())
        return .result(value: text, dialog: IntentDialog(stringLiteral: text))
    }
}
