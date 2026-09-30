import Foundation
import KinhinKit
import Observation

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
        /// Advisory caveat rendered under the detail (the drift warning);
        /// the dot still reflects `ok`, which stays true for a usable
        /// but non-reproducible base image.
        var warning: String? = nil
        var id: String { title }
    }

    private(set) var rows: [Row] = []
    var status = "Probing this Mac…"

    /// Runs the doctor probe set (the same builder `kinhin doctor --json`
    /// uses) and renders the result. Injectable so tests can render a
    /// fixture report instead of subprocess-probing the host.
    @ObservationIgnored var loadReport: () async -> DoctorReport = { await DoctorReportBuilder().build() }

    func load() async {
        status = "Probing this Mac…"
        render(await loadReport())
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

        // The configured `base_image:` — only worth a row when the same
        // warning the fleet-start log prints applies (a mutable tag bakes
        // differently every time). Pinned or absent → no row.
        if let base = report.tartBaseImage, let warning = base.warning {
            var detail = "\(base.reference) — \(base.fix ?? "")"
            if detail.hasSuffix(" — ") { detail = String(detail.dropLast(3)) }
            rows.append(Row(title: "Base image (macOS VMs)", detail: detail, ok: base.ok, warning: warning))
        }

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
            if let note = docker.note { detail += "\n\(note)" }
            rows.append(Row(title: "Docker (Linux)", detail: detail, ok: docker.ok))
        } else if let availability = report.dockerAvailability {
            // Not enabled in the config: still say whether it could be.
            let detail: String
            if let reason = availability.reason {
                detail = "not supported on this Mac — \(reason)"
            } else if availability.installed {
                detail = "installed — not enabled for Linux jobs (turn it on in This Mac)"
            } else {
                detail = "not installed — optional, runs Linux jobs (install it from This Mac)"
            }
            rows.append(Row(title: "Docker (Linux)", detail: detail, ok: availability.supported))
        }

        // Capacity (nil when the config can't parse — nothing to plan against)
        if let capacity = report.capacity {
            rows.append(
                Row(
                    title: "Capacity",
                    detail:
                        "\(capacity.maxConcurrent) VMs · \(capacity.jobSlots) job slots — \(capacity.bindingConstraint)",
                    ok: capacity.fits))
        }

        let cache = report.toolchainCache
        var cacheDetail = "\(ByteCountFormatter.string(fromByteCount: cache.totalBytes, countStyle: .file)) cached"
        if cache.warning { cacheDetail += " — shared with runners but empty (run image prepare)" }
        rows.append(Row(title: "Toolchain cache", detail: cacheDetail, ok: cache.usable))

        self.rows = rows
    }
}
