import Foundation
import KinhinKit
import Observation

/// State behind the Fleet tab: the latest fleet status and the actions its
/// buttons trigger. The window controller feeds it statuses and wires the
/// callbacks to its delegate.
@MainActor
@Observable
final class FleetModel {
    @ObservationIgnored var onStart: () -> Void = {}
    @ObservationIgnored var onStop: () -> Void = {}
    @ObservationIgnored var onPause: () -> Void = {}
    @ObservationIgnored var onResume: () -> Void = {}
    @ObservationIgnored var onDeleteVM: (String) -> Void = { _ in }
    @ObservationIgnored var onShowLogs: () -> Void = {}
    @ObservationIgnored var onShowDiagnostics: () -> Void = {}

    /// Nil until the first poll (or when setup isn't finished).
    var status: FleetStatus?

    /// A start/stop command is in flight: its button shows a progress
    /// indicator and the fleet controls disable until the command and its
    /// status refresh complete (`endPendingAction`).
    enum PendingAction {
        case start
        case stop
    }

    private(set) var pendingAction: PendingAction?
    /// The app delegate mirrors its own pending state here (menu items and
    /// App Intents can begin a fleet action too, with no button click).
    func setPending(_ action: PendingAction?) { pendingAction = action }
    var isBusy: Bool { pendingAction != nil }

    var statusLine: String { AppDelegate.statusLineText(for: status) }
    var running: Bool { status?.running ?? false }
    var paused: Bool { status?.paused ?? false }
    var pauseTitle: String { paused ? "Resume" : "Pause" }
    var records: [VMRecord] { status?.records ?? [] }
    /// The VMs currently running a workflow.
    var working: [VMRecord] { records.filter { $0.job != nil } }

    /// Button entry points: mark the in-flight action, then dispatch. A
    /// second click while busy is a no-op (the buttons disable too — this is
    /// the state-level backstop).
    func startClicked() {
        guard !isBusy else { return }
        pendingAction = .start
        onStart()
    }

    func stopClicked() {
        guard !isBusy else { return }
        pendingAction = .stop
        onStop()
    }

    /// Called by the action owner (the app delegate) when the command and its
    /// status refresh are done — success, failure, or not-set-up alike.
    func endPendingAction() {
        pendingAction = nil
    }

    func togglePause() {
        guard !isBusy else { return }
        if paused { onResume() } else { onPause() }
    }

    // MARK: Row text

    func title(for record: VMRecord) -> String { "• \(record.id) — \(record.phase.rawValue)" }

    func detail(for record: VMRecord) -> String {
        var parts: [String] = []
        if let repos = record.repos, !repos.isEmpty {
            parts.append(repos.count == 1 ? repos[0] : "\(repos.count) repos")
        }
        if let job = record.job { parts.append(job) }
        if let err = record.error { parts.append("⚠︎ \(err)") }
        return parts.joined(separator: " · ")
    }

    func jobLine(for record: VMRecord) -> String {
        let repoText = record.repos?.joined(separator: ", ") ?? ""
        return "▸ \(record.job ?? "") — \(repoText)  (\(record.id), \(record.phase.rawValue))"
    }
}
