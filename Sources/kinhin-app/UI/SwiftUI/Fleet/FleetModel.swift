import Foundation
import KinhinKit
import Observation

/// State behind the Fleet tab: reads the latest fleet status and the in-flight
/// action from `FleetController` (the single source of truth); its buttons
/// call the controller directly.
@MainActor
@Observable
final class FleetModel {
    /// Set by the window: Start with nothing configured, and the two sheets.
    @ObservationIgnored var onNeedsSetup: () -> Void = {}
    @ObservationIgnored var onShowLogs: () -> Void = {}
    @ObservationIgnored var onShowDiagnostics: () -> Void = {}

    @ObservationIgnored let controller: FleetController

    init(controller: FleetController) {
        self.controller = controller
    }

    /// Nil until the first poll (or when setup isn't finished).
    var status: FleetStatus? { controller.status }

    /// A start/stop command in flight (from a button, the menu, or an App
    /// Intent): its button shows a progress indicator and the fleet controls
    /// disable until the command and its status refresh complete.
    var pendingAction: FleetAction? { controller.pendingFleetAction }
    var isBusy: Bool { pendingAction != nil }

    var statusLine: String { controller.statusLine }
    /// Set while a per-project image bakes (jobs use the base image meanwhile).
    /// Informational, not an error.
    var imageNotice: String? { status?.imageNotice }
    var running: Bool { status?.running ?? false }
    var paused: Bool { status?.paused ?? false }
    /// Non-nil while the fleet is paused with auto-resume on: shown on the
    /// Fleet tab so a deliberate pause (e.g. a pause-first delete from
    /// Shortcuts) doesn't read as stuck. Names the poll cadence when the
    /// status carries it; older daemons get the timeless wording.
    var pausedAutoResumeNote: String? {
        guard paused, let autoResume = status?.autoResume, autoResume else { return nil }
        if let cadence = status?.autoResumeCadence {
            return "Auto-resume is on — the engine \(cadence)."
        }
        return "Auto-resume is on — the fleet releases itself when the queue is empty."
    }
    var pauseTitle: String { paused ? "Resume" : "Pause" }
    var records: [VMRecord] { status?.records ?? [] }
    /// The VMs currently running a workflow.
    var working: [VMRecord] { records.filter { $0.job != nil } }

    /// Button entry points. A second click while busy is a no-op (the
    /// buttons disable too — this is the state-level backstop).
    func startClicked() {
        guard !isBusy else { return }
        controller.userStart(openSetup: onNeedsSetup)
    }

    func stopClicked() {
        guard !isBusy else { return }
        controller.userStop()
    }

    func togglePause() {
        guard !isBusy else { return }
        controller.userSetPaused(!paused)
    }

    func deleteClicked(_ id: String) {
        controller.userDeleteVM(id: id)
    }

    // MARK: - Row text

    func title(for record: VMRecord) -> String { "• \(record.id) — \(record.phase.rawValue)" }

    func detail(for record: VMRecord) -> String {
        var parts: [String] = []
        if let repos = FleetStatusFormatter.repos(of: record) { parts.append(repos) }
        if let job = record.job { parts.append(job) }
        if let usage = FleetStatusFormatter.usage(of: record) { parts.append(usage) }
        if let err = record.error { parts.append("⚠︎ \(err)") }
        return parts.joined(separator: " · ")
    }

    func jobLine(for record: VMRecord) -> String {
        let repoText = record.repos?.joined(separator: ", ") ?? ""
        return "▸ \(record.job ?? "") — \(repoText)  (\(record.id), \(record.phase.rawValue))"
    }
}
