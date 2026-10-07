import Foundation
import KinhinKit

/// The Fleet tab's runtime diagram, reduced to pure display values: one lane
/// per execution runtime, every live instance as one icon-led row (the old
/// VM list nested under the runtime that serves it), and an
/// explicit "idle" for a runtime with nothing running. Derived only from a
/// `FleetStatus` snapshot (the same one the status line renders), so the
/// picture can never disagree with the text below it. No I/O.
struct FleetDiagramModel {
    /// One live instance, reduced to what its row draws.
    struct Instance: Identifiable {
        let id: String
        let phase: VMPhase
        /// SF Symbol name drawn in the row's leading icon.
        let symbol: String
        let style: StatusStyle
        /// Row title: "• kinhin-x — busy" (monospaced in the row).
        let title: String
        /// Row detail line — repos · job · usage · ⚠ error; "" when none.
        let detail: String
        /// The detail line is red: the instance carries an error.
        let hasError: Bool
        /// Tapping the row's icon or text opens the live pipeline sheet (only
        /// an instance that can hold a job has a pipeline to show).
        let opensPipeline: Bool

        /// Tooltip and VoiceOver text: the title, then the detail facts.
        var tooltip: String { detail.isEmpty ? title : "\(title) — \(detail)" }
    }

    /// One runtime lane: identity, cap, and its instances — none means idle.
    struct Lane: Identifiable {
        let id: RuntimeID
        /// Identity mark (emoji), shared with the Routing pane and the CLI.
        let mark: String
        /// "Tart VMs (macOS)" — the mark lives in `mark`, not in the title.
        let title: String
        /// Instance cap for a mixed fleet (nil on a single-pool fleet, or for
        /// a runtime that only shows up through its records).
        let cap: Int?
        /// In the status's own order — the same order the VM list showed.
        let instances: [Instance]

        var isIdle: Bool { instances.isEmpty }
        var busyCount: Int { instances.count { $0.phase == .busy } }
        /// "3 instances · cap 4"; nil on an idle lane (it says "idle" instead).
        var countText: String? {
            guard !instances.isEmpty else { return nil }
            var text = "\(instances.count) instance\(instances.count == 1 ? "" : "s")"
            if let cap { text += " · cap \(cap)" }
            return text
        }
    }

    /// Lanes in presentation order (tart, apple container, docker, host).
    let lanes: [Lane]

    /// Instances across every lane, and how many of them hold a job.
    var instanceCount: Int { lanes.reduce(0) { $0 + $1.instances.count } }
    var busyCount: Int { lanes.reduce(0) { $0 + $1.busyCount } }

    init(status: FleetStatus?) {
        guard let status else {
            lanes = []
            return
        }
        // Which runtimes the fleet is configured for: the per-runtime caps of
        // a mixed fleet name its pools; a single-pool fleet reports none and
        // serves everything through one runtime (nil = tart on old records).
        var caps: [RuntimeID: Int] = [:]
        var configured = Set<RuntimeID>()
        for (raw, value) in status.capacityByRuntime ?? [:] {
            guard let id = RuntimeID(rawValue: raw) else { continue }
            caps[id] = Int(value)
            configured.insert(id)
        }
        if configured.isEmpty {
            configured.insert(RuntimeID(rawValue: status.runtime ?? "") ?? .tart)
        }
        // Instances grouped by the runtime that serves them. A runtime the
        // config doesn't name but that still holds instances (restart
        // recovery adopting strays) gets a lane too, so nothing that runs is
        // ever invisible.
        var grouped: [RuntimeID: [VMRecord]] = [:]
        for record in status.records {
            let id = RuntimeID(rawValue: record.runtime ?? "") ?? .tart
            grouped[id, default: []].append(record)
        }
        configured.formUnion(grouped.keys)
        // RuntimeID.allCases is the canonical lane order (tart, apple
        // container, docker, host); records keep their status order inside a
        // lane, so the rows read exactly like the old VM list did.
        lanes = RuntimeID.allCases.filter(configured.contains).map { id in
            let name = Self.identity(id)
            return Lane(
                id: id,
                mark: name.mark,
                title: name.title,
                cap: caps[id],
                instances: (grouped[id] ?? []).map(Self.instance)
            )
        }
    }

    // MARK: - Pieces

    /// Whether an instance has a pipeline to open: it is busy, or a job is
    /// already assigned to it. One rule — `FleetModel.hasPipeline` delegates
    /// here, so the row and the pipeline sheet agree.
    static func opensPipeline(_ record: VMRecord) -> Bool {
        record.phase == .busy || record.job != nil
    }

    /// The identity mark and title, matching the Routing pane and the CLI
    /// (🍎 Tart VMs, 🐧 Apple containers, 🐳 Docker, 🖥 Host).
    private static func identity(_ id: RuntimeID) -> (mark: String, title: String) {
        switch id {
        case .tart: return ("🍎", "Tart VMs (macOS)")
        case .appleContainer: return ("🐧", "Apple containers (Linux)")
        case .docker: return ("🐳", "Docker (Linux)")
        case .host: return ("🖥", "Host (this Mac)")
        }
    }

    /// One record reduced to an icon-led row: the phase-colored icon, the
    /// row title, and the detail line — the same facts (and the same order)
    /// the old VM list row showed.
    private static func instance(_ record: VMRecord) -> Instance {
        let symbol: String
        let style: StatusStyle
        if record.error != nil {
            symbol = "exclamationmark.triangle.fill"
            style = .error
        } else {
            switch record.phase {
            case .busy:
                symbol = "bolt.fill"
                style = .ok
            case .ready:
                symbol = "checkmark.circle"
                style = .secondary
            case .cloning, .booting, .registering:
                symbol = "arrow.triangle.2.circlepath"
                style = .secondary
            case .deleting:
                symbol = "xmark.circle"
                style = .secondary
            case .failed:
                symbol = "exclamationmark.triangle.fill"
                style = .error
            }
        }
        var parts: [String] = []
        if let repos = FleetStatusFormatter.repos(of: record) { parts.append(repos) }
        if let job = record.job { parts.append(job) }
        if let usage = FleetStatusFormatter.usage(of: record) { parts.append(usage) }
        if let error = record.error { parts.append("⚠︎ \(error)") }
        return Instance(
            id: record.id,
            phase: record.phase,
            symbol: symbol,
            style: style,
            title: "• \(record.id) — \(record.phase.rawValue)",
            detail: parts.joined(separator: " · "),
            hasError: record.error != nil,
            opensPipeline: opensPipeline(record)
        )
    }
}
