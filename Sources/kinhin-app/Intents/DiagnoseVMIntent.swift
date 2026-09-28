import AppIntents

struct DiagnoseVMIntent: AppIntent {
    static let title: LocalizedStringResource = "Diagnose VM"
    static let description = IntentDescription(
        "Reports one runner VM's phase, assigned job, and last error — useful before deleting a stalled VM.")

    /// Picked from the fleet's current VMs (id + phase).
    @Parameter(title: "VM") var vm: VMEntity?

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        guard let vm else { return .result(dialog: IntentDialog(stringLiteral: "No VM was chosen.")) }
        let text = try await DiagnoseVMAction.run(id: vm.id)
        return .result(dialog: IntentDialog(stringLiteral: text))
    }
}

/// Read-only, so there is nothing to make idempotent: one status fetch and
/// a spoken summary. Sharing the picker entity with Delete VM means the
/// same shortcut can diagnose before deleting.
@MainActor
enum DiagnoseVMAction {
    static func run(id: String) async throws -> String {
        let status = try await FleetIntentEnvironment.bridge.status()
        let record = status.records.first { $0.id == id }
        return FleetSummary.diagnose(id: id, record: record)
    }
}
