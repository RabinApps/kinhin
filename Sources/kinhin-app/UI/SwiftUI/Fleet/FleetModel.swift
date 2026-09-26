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

    var statusLine: String { AppDelegate.statusLineText(for: status) }
    var running: Bool { status?.running ?? false }
    var paused: Bool { status?.paused ?? false }
    var pauseTitle: String { paused ? "Resume" : "Pause" }
    var records: [VMRecord] { status?.records ?? [] }
    /// The VMs currently running a workflow.
    var working: [VMRecord] { records.filter { $0.job != nil } }

    func togglePause() {
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
