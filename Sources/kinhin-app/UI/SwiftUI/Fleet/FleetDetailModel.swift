import Foundation
import KinhinKit
import Observation

/// State behind the Fleet tab's new Detail page: one status poll drives the
/// VM rows, the per-repo queue/running breakdown, and the selected VM's
/// lifecycle details (IP, phase timeline, attached runners, current job).
///
/// Mode is set by the user (All / Queued / Running / Cancelled) and gates the
/// visible rows.
@MainActor
@Observable
final class FleetDetailModel {
    /// The engine/daemon the model reads through.
    @ObservationIgnored let controller: FleetController

    /// "all" | "queued" | "running" | "cancelled".
    var mode: DetailMode = .all
    private(set) var modeText = "All"
    /// The filtered VM rows shown in the detail table (maps to `status` after
    /// `refresh()` applies the `mode` filter).
    private(set) var records: [VMRecord] = []
    private(set) var breakdownText = ""
    private(set) var noWorkText = ""

    /// The fleet's latest status: the single source of truth for rows and the
    /// breakdown. Nil until the first poll (or when setup is unfinished).
    var status: FleetStatus? { controller.status }

    /// What the status line shows next to the tab label (shows when the queue
    /// was last observed).
    var statusLine: String { controller.statusLine }

    /// The selected VM, whose lifecycle details the drill-down renders. Nil
    /// shows an empty detail pane. A fresh model per opening; the view
    /// re-reads `selectedVM` after every refresh.
    var selectedVMID: String?

    /// Running task behind the poll loop (kept so a destructive action can
    /// cancel it).
    @ObservationIgnored private(set) var refreshTask: Task<Void, Never>?

    enum DetailMode: String, CaseIterable {
        case all
        case queued
        case running
        case cancelled

        var label: String {
            switch self {
            case .all: return "All"
            case .queued: return "Queued"
            case .running: return "Running"
            case .cancelled: return "Cancelled"
            }
        }
    }

    /// One VM row in the detail table: its identity plus a compact lifecycle
    /// summary.
    struct VMRow: Identifiable, Equatable {
        let id: String
        let phase: VMPhase
        /// The runner this VM is attached to (nil for idle VMs).
        let runnerName: String?
        /// The workflow job this VM is currently executing (nil when idle).
        let job: String?
        /// The VM's network address (nil when no network is configured).
        let ip: String?

        var title: String { "\(id) — \(phase.rawValue)" }

        var detail: String {
            var parts: [String] = []
            if let runner = runnerName { parts.append("runner \(runner)") }
            if let job = job { parts.append("job \(job)") }
            if let ip = ip { parts.append("ip \(ip)") }
            if !parts.isEmpty { return parts.joined(separator: ", ") }
            return "no active job"
        }
    }

    init(controller: FleetController) {
        self.controller = controller
    }

    // MARK: - Loading

    /// One poll of everything on screen: the VM rows, the breakdown and the
    /// no-work note. Runs on the main actor (the controller polls off the
    /// main actor).
    func refresh() async {
        await loadRows()
        await loadBreakdown()
        await loadEmptyNote()
    }

    /// One poll of the visible VM rows only.
    func refreshRows() async {
        await loadRows()
    }

    private func loadRows() async {
        let desired: [VMRecord]
        switch mode {
        case .all:
            desired = status?.records ?? []
        case .queued:
            desired = status?.records.filter { $0.phase == .ready } ?? []
        case .running:
            desired = status?.records.filter { $0.phase == .busy } ?? []
        case .cancelled:
            desired = status?.records.filter { $0.phase == .failed } ?? []
        }
        records = desired
        selectedVMID = nil
        // Rebuild the rows in the status's order.
        for record in desired where record.id != selectedVMID {
            _ = record
        }
        modeText = mode.label
    }

    private func loadBreakdown() async {
        var queued: [String: Int] = [:]
        var running: [String: Int] = [:]
        for record in status?.records ?? [] {
            for repo in record.repos ?? [] {
                if record.phase == .ready { queued[repo, default: 0] += 1 }
                if record.phase == .busy { running[repo, default: 0] += 1 }
            }
        }
        breakdownText = ""
        if !queued.isEmpty { breakdownText += "Queued: " + FleetStatusFormatter.repoBreakdown(queued) + "\n" }
        if !running.isEmpty { breakdownText += "Running: " + FleetStatusFormatter.repoBreakdown(running) + "\n" }
        noWorkText = ""
        if status?.records.isEmpty == true {
            noWorkText = "No VMs yet. Start the fleet from the Fleet tab."
        } else if breakdownText.isEmpty {
            noWorkText = "No jobs to show in this view."
        }
        if mode != .all && status?.queueDepth == 0 {
            noWorkText = "The queue is empty — the fleet is idle."
        }
    }

    private func loadEmptyNote() async {
        if status?.records.isEmpty == true {
            noWorkText = "No VMs yet. Start the fleet from the Fleet tab."
        } else if breakdownText.isEmpty {
            noWorkText = "No jobs to show in this view."
        }
    }

    /// The lifecycle detail for one VM: its phase, the runner it is attached
    /// to, its current job and its IP.
    func vmDetail(for id: String) -> VMRow? {
        guard let record = status?.records.first(where: { $0.id == id }) else { return nil }
        return VMRow(id: record.id, phase: record.phase, runnerName: record.runnerName, job: record.job, ip: record.ip)
    }

    func selectVM(_ id: String) {
        selectedVMID = id
    }
}


