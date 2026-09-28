import AppIntents

struct DeleteVMIntent: AppIntent {
    static let title: LocalizedStringResource = "Delete VM"
    static let description = IntentDescription(
        "Deletes a stalled runner VM without opening the window. Pauses first so autoscale can't recreate it.")

    /// Picked from the fleet's current VMs (id + phase); typed ids work too.
    @Parameter(title: "VM") var vm: VMEntity?

    /// On by default: a plain delete is undone by autoscale within one poll
    /// when demand remains.
    @Parameter(title: "Pause Fleet First", default: true) var pauseFirst: Bool

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        guard let vm else { return .result(dialog: IntentDialog(stringLiteral: "No VM was chosen.")) }
        let text = try await DeleteVMAction.run(id: vm.id, pauseFirst: pauseFirst)
        return .result(dialog: IntentDialog(stringLiteral: text))
    }
}

/// Deletes without a confirmation dialog: AppIntents can't present NSAlert,
/// and picking the VM in Shortcuts is itself the explicit instruction
/// (Shortcuts offers its own Confirm Before Running toggle).
@MainActor
enum DeleteVMAction {
    static func run(id: String, pauseFirst: Bool = false) async throws -> String {
        let bridge = FleetIntentEnvironment.bridge
        let before = try await bridge.status()
        // Check existence before pausing: an unknown id must not pause the
        // fleet as a side effect.
        guard before.records.contains(where: { $0.id == id }) else {
            return FleetSummary.deleteResult(id: id, outcome: .notFound)
        }
        // Only pause when it changes something — a stopped or already-paused
        // fleet has no autoscaler to hold back. A failed pause aborts the
        // delete so the error surfaces instead of a pointless delete.
        var pausedFirst = false
        if pauseFirst, before.running, !before.paused {
            try await bridge.setPaused(true)
            pausedFirst = true
        }
        try await bridge.deleteVM(id: id)
        let after = try await bridge.status()
        // Teardown is async: the record can still be listed right after the
        // command ran, so only a missing record counts as done.
        let stillThere = after.records.contains { $0.id == id }
        return FleetSummary.deleteResult(id: id, outcome: stillThere ? .uncertain : .deleted, pausedFirst: pausedFirst)
    }
}
