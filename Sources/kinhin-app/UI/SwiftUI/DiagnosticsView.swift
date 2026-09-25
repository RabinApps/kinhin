import KinhinKit
import Observation
import SwiftUI

/// State behind the Diagnostics sheet: the doctor report flattened into
/// display rows. Kept separate from the view so tests can pin the report
/// layout without loading any UI.
@MainActor
@Observable
final class DiagnosticsModel {
    struct Row: Identifiable, Equatable {
        let title: String
        let detail: String
        let ok: Bool
        var id: String { title }
    }

    private(set) var rows: [Row] = []
    var status = "Probing this Mac…"

    /// Runs the doctor probe set (the same builder `kinhin doctor --json`
    /// uses) and renders the result.
    func load() async {
        status = "Probing this Mac…"
        let report = await DoctorReportBuilder().build()
        render(report)
        let stamp = DateFormatter.localizedString(from: Date(), dateStyle: .none, timeStyle: .medium)
        status = "Checked \(stamp)"
    }

    func render(_ report: DoctorReport) {
        var rows: [Row] = []

        rows.append(
            Row(
                title: "Host",
                detail:
                    "\(report.host.logicalCores) cores · \(report.host.memoryGB) GB RAM · \(report.host.freeDiskGB) GB free · \(report.host.arm64 ? "Apple silicon" : "Intel")",
                ok: true))

        let cltOK = report.clt.ok
        var cltDetail = report.clt.version ?? report.clt.state
        if !cltOK, let fix = report.clt.fixCommand { cltDetail += "\n\(fix)" }
        rows.append(Row(title: "Command Line Tools", detail: cltDetail, ok: cltOK))

        var tartDetail = report.tart.reason ?? (report.tart.ok ? "healthy" : report.tart.state)
        if !report.tart.repairCommands.isEmpty {
            tartDetail += "\nFix: \(report.tart.repairCommands[0])"
        }
        rows.append(Row(title: "Tart (macOS VMs)", detail: tartDetail, ok: report.tart.ok))

        // Containers (only when configured)
        if let container = report.container {
            var detail = container.fix ?? "ready — image \(container.image)"
            if !container.imageFound {
                detail += "\nimage \(container.image) not built yet (kinhin image prepare --container)"
            }
            rows.append(Row(title: "Apple container (Linux)", detail: detail, ok: container.ok))
        }
        if let docker = report.docker {
            var detail = docker.fix ?? "ready — image \(docker.image)"
            if !docker.imageFound { detail += "\nimage \(docker.image) not built yet (kinhin image prepare --docker)" }
            rows.append(Row(title: "Docker (Linux)", detail: detail, ok: docker.ok))
        }

        // Capacity (nil when the config can't parse — nothing to plan against)
        if let capacity = report.capacity {
            rows.append(
                Row(
                    title: "Capacity",
                    detail: "\(capacity.maxConcurrent) VMs · \(capacity.jobSlots) job slots — \(capacity.bindingConstraint)",
                    ok: capacity.fits))
        }

        let cache = report.toolchainCache
        var cacheDetail = "\(ByteCountFormatter.string(fromByteCount: cache.totalBytes, countStyle: .file)) cached"
        if cache.warning { cacheDetail += " — shared with runners but empty (run image prepare)" }
        rows.append(Row(title: "Toolchain cache", detail: cacheDetail, ok: cache.usable))

        self.rows = rows
    }
}

/// The Diagnostics sheet content: header, one card per check, Close.
struct DiagnosticsView: View {
    static let size = CGSize(width: 560, height: 520)

    let model: DiagnosticsModel
    let onClose: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text("🩺  Diagnostics").font(.system(size: 18, weight: .bold))
                StatusText(text: model.status)
            }
            ScrollView {
                VStack(spacing: 8) {
                    ForEach(model.rows) { row in
                        DiagnosticsRow(row: row)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            HStack {
                Spacer()
                Button("Close", action: onClose)
                    .keyboardShortcut(.defaultAction)
                    .accessibilityLabel("Close diagnostics")
            }
        }
        .padding(.horizontal, 20)
        .padding(.top, 16)
        .padding(.bottom, 14)
        .frame(width: Self.size.width, height: Self.size.height, alignment: .topLeading)
    }
}

private struct DiagnosticsRow: View {
    let row: DiagnosticsModel.Row

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text("●")
                .font(.system(size: 14, weight: .bold))
                .foregroundStyle(row.ok ? StatusStyle.ok.color : StatusStyle.error.color)
            VStack(alignment: .leading, spacing: 2) {
                Text(row.title).font(.system(size: 13, weight: .semibold))
                // Selectable so fix commands can be copied.
                Text(row.detail)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(width: 500, alignment: .leading)
        .formSurface(cornerRadius: 8)
    }
}
