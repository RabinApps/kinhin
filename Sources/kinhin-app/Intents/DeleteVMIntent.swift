import AppIntents

struct DeleteVMIntent: AppIntent {
    static let title: LocalizedStringResource = "Delete VM"
    static let description = IntentDescription(
        "Deletes one runner VM by id — for a stalled VM that should be removed without opening the window.")

    /// The VM id as shown on the Fleet tab (the tart VM name).
    @Parameter(title: "VM") var vm: String

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let text = try await DeleteVMAction.run(id: vm)
        return .result(dialog: IntentDialog(stringLiteral: text))
    }
}

/// Deletes without a confirmation dialog: AppIntents can't present NSAlert,
/// and picking the VM id in Shortcuts is itself the explicit instruction
/// (Shortcuts offers its own Confirm Before Running toggle).
@MainActor
enum DeleteVMAction {
    static func run(id: String) async throws -> String {
        let bridge = FleetIntentEnvironment.bridge
        let before = try await bridge.status()
        guard before.records.contains(where: { $0.id == id }) else {
            return FleetSummary.deleteResult(id: id, outcome: .notFound)
        }
        try await bridge.deleteVM(id: id)
        let after = try await bridge.status()
        // Teardown is async: the record can still be listed right after the
        // command ran, so only a missing record counts as done.
        let stillThere = after.records.contains { $0.id == id }
        return FleetSummary.deleteResult(id: id, outcome: stillThere ? .uncertain : .deleted)
    }
}
