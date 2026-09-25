import AppIntents

struct RunDoctorIntent: AppIntent {
    static let title: LocalizedStringResource = "Run Diagnostics"
    static let description = IntentDescription(
        "Checks that Tart, the container runtimes, credentials and the base image are ready.")

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<String> & ProvidesDialog {
        let text = FleetSummary.doctor(await FleetIntentEnvironment.bridge.doctor())
        return .result(value: text, dialog: IntentDialog(stringLiteral: text))
    }
}
