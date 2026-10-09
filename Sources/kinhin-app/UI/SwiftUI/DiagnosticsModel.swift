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
    /// The fleet's current image-bake notice, when one is showing.
    @ObservationIgnored var fleetImageNotice: () -> String? = { nil }
    var status = String(
        localized: "Probing this Mac…", bundle: .l10n, comment: "Diagnostics sheet status while probing")

    /// Runs the doctor probe set (the same builder `kinhin doctor --json`
    /// uses) and renders the result. Injectable so tests can render a
    /// fixture report instead of subprocess-probing the host.
    @ObservationIgnored var loadReport: () async -> DoctorReport = { await DoctorReportBuilder().build() }

    func load() async {
        status = String(
            localized: "Probing this Mac…", bundle: .l10n, comment: "Diagnostics sheet status while probing")
        render(await loadReport())
        let stamp = DateFormatter.localizedString(from: Date(), dateStyle: .none, timeStyle: .medium)
        status = String(
            localized: "Checked \(stamp)", bundle: .l10n,
            comment: "Diagnostics sheet status; %@ is the localized time of day")
    }

    func render(_ report: DoctorReport) {
        var rows: [Row] = []

        rows.append(
            Row(
                title: String(localized: "Host", bundle: .l10n, comment: "Diagnostics row title"),
                detail: report.host.arm64
                    ? String(
                        localized:
                            "\(report.host.logicalCores) cores · \(report.host.memoryGB) GB RAM · \(report.host.freeDiskGB) GB free · Apple silicon",
                        bundle: .l10n,
                        comment: "Diagnostics Host row on Apple silicon; cores, then GB of RAM and free disk")
                    : String(
                        localized:
                            "\(report.host.logicalCores) cores · \(report.host.memoryGB) GB RAM · \(report.host.freeDiskGB) GB free · Intel",
                        bundle: .l10n, comment: "Diagnostics Host row on Intel; cores, then GB of RAM and free disk"),
                ok: true))

        let cltOK = report.clt.ok
        var cltDetail = report.clt.version ?? report.clt.state
        if !cltOK, let fix = report.clt.fixCommand { cltDetail += "\n\(fix)" }
        rows.append(
            Row(
                title: String(localized: "Command Line Tools", bundle: .l10n, comment: "Diagnostics row title"),
                detail: cltDetail, ok: cltOK))

        var tartDetail =
            report.tart.reason
            ?? (report.tart.ok
                ? String(localized: "healthy", bundle: .l10n, comment: "Diagnostics Tart row detail")
                : report.tart.state)
        if !report.tart.repairCommands.isEmpty {
            tartDetail +=
                "\n"
                + String(
                    localized: "Fix: \(report.tart.repairCommands[0])", bundle: .l10n,
                    comment: "Diagnostics Tart row; %@ is a shell command to run")
        }
        rows.append(
            Row(
                title: String(localized: "Tart (macOS VMs)", bundle: .l10n, comment: "Diagnostics row title"),
                detail: tartDetail, ok: report.tart.ok))

        // The configured `base_image:` — only worth a row when the same
        // warning the fleet-start log prints applies (a mutable tag bakes
        // differently every time). Pinned or absent → no row.
        if let base = report.tartBaseImage, let warning = base.warning {
            var detail = "\(base.reference) — \(base.fix ?? "")"
            if detail.hasSuffix(" — ") { detail = String(detail.dropLast(3)) }
            rows.append(
                Row(
                    title: String(localized: "Base image (macOS VMs)", bundle: .l10n, comment: "Diagnostics row title"),
                    detail: detail, ok: base.ok, warning: warning))
        }

        // Containers (only when configured)
        if let container = report.container {
            var detail =
                container.fix
                ?? String(
                    localized: "ready — image \(container.image)", bundle: .l10n,
                    comment: "Diagnostics Apple container row; %@ is an image name")
            if !container.imageFound {
                detail +=
                    "\n"
                    + String(
                        localized: "image \(container.image) not built yet (kinhin image prepare --container)",
                        bundle: .l10n,
                        comment: "Diagnostics Apple container row; %@ is an image name; the command stays verbatim")
            }
            rows.append(
                Row(
                    title: String(
                        localized: "Apple container (Linux)", bundle: .l10n, comment: "Diagnostics row title"),
                    detail: detail, ok: container.ok))
        }
        if let docker = report.docker {
            var detail =
                docker.fix
                ?? String(
                    localized: "ready — image \(docker.image)", bundle: .l10n,
                    comment: "Diagnostics Docker row; %@ is an image name")
            if !docker.imageFound {
                detail +=
                    "\n"
                    + String(
                        localized: "image \(docker.image) not built yet (kinhin image prepare --docker)", bundle: .l10n,
                        comment: "Diagnostics Docker row; %@ is an image name; the command stays verbatim")
            }
            if let note = docker.note { detail += "\n\(note)" }
            rows.append(
                Row(
                    title: String(localized: "Docker (Linux)", bundle: .l10n, comment: "Diagnostics row title"),
                    detail: detail, ok: docker.ok))
        } else if let availability = report.dockerAvailability {
            // Not enabled in the config: still say whether it could be.
            let detail: String
            if let reason = availability.reason {
                detail = String(
                    localized: "not supported on this Mac — \(reason)", bundle: .l10n,
                    comment: "Diagnostics Docker row; %@ is the reason")
            } else if availability.installed {
                detail = String(
                    localized: "installed — not enabled for Linux jobs (turn it on in This Mac)", bundle: .l10n,
                    comment: "Diagnostics Docker row")
            } else {
                detail = String(
                    localized: "not installed — optional, runs Linux jobs (install it from This Mac)", bundle: .l10n,
                    comment: "Diagnostics Docker row")
            }
            rows.append(
                Row(
                    title: String(localized: "Docker (Linux)", bundle: .l10n, comment: "Diagnostics row title"),
                    detail: detail, ok: availability.supported))
        }

        // Per-runtime image disk usage — the same line the human doctor
        // prints (`images:` row), so both surfaces say exactly this much.
        // Informational: a big number is bloat to prune, not a fault.
        if let usage = report.imageTotalLine {
            rows.append(
                Row(
                    title: String(localized: "Image disk usage", bundle: .l10n, comment: "Diagnostics row title"),
                    detail: usage, ok: true))
        }

        // …and the sweep that would give some of that space back, straight
        // from the report's prune plan — the same line the doctor's `prune:`
        // row prints, present only when something is actually wasting disk.
        if let prune = report.imagePruneLine {
            rows.append(
                Row(
                    title: String(localized: "Unused images", bundle: .l10n, comment: "Diagnostics row title"),
                    detail: prune, ok: true))
        }

        // Capacity (nil when the config can't parse — nothing to plan against)
        if let capacity = report.capacity {
            rows.append(
                Row(
                    title: String(localized: "Capacity", bundle: .l10n, comment: "Diagnostics row title"),
                    detail:
                        String(
                            localized:
                                "\(capacity.maxConcurrent) VMs · \(capacity.jobSlots) job slots — \(capacity.bindingConstraint)",
                            bundle: .l10n,
                            comment: "Diagnostics Capacity row; VM count, then job slots, then the limiting factor"),
                    ok: capacity.fits))
        }

        // The engine's disk guard, before the fleet hits it — not ok: the
        // next spawn is held until disk frees. Same shared line as the
        // doctor's WARNING, image totals and prune lever included.
        if let pressure = report.diskPressureLine {
            rows.append(
                Row(
                    title: String(localized: "Disk pressure", bundle: .l10n, comment: "Diagnostics row title"),
                    detail: pressure, ok: false))
        }

        if let security = report.security {
            let detail: String
            if security.softnetEnabled {
                detail =
                    security.softnetInstalled
                    ? String(
                        localized: "Softnet on — runner VMs are isolated from each other and the LAN", bundle: .l10n,
                        comment: "Diagnostics security row")
                    : String(
                        localized:
                            "Softnet is on but not installed — \(security.fix ?? "install softnet"). The fleet will not start.",
                        bundle: .l10n, comment: "Diagnostics security row; %@ is the fix command")

            } else {
                detail = String(
                    localized: "Softnet off — runner VMs share one network", bundle: .l10n,
                    comment: "Diagnostics security row")
            }
            rows.append(
                Row(
                    title: String(localized: "Isolation & transport", bundle: .l10n, comment: "Diagnostics row title"),
                    detail: detail, ok: security.ok,
                    warning: security.warnings.isEmpty ? nil : security.warnings.joined(separator: "\n")))
        }

        let cache = report.toolchainCache
        let cacheSize = ByteCountFormatter.string(fromByteCount: cache.totalBytes, countStyle: .file)
        let cacheDetail =
            cache.warning
            ? String(
                localized: "\(cacheSize) cached — shared with runners but empty (run image prepare)", bundle: .l10n,
                comment: "Diagnostics toolchain-cache row; %@ is a formatted byte count")
            : String(
                localized: "\(cacheSize) cached", bundle: .l10n,
                comment: "Diagnostics toolchain-cache row; %@ is a formatted byte count")
        rows.append(
            Row(
                title: String(localized: "Toolchain cache", bundle: .l10n, comment: "Diagnostics row title"),
                detail: cacheDetail, ok: cache.usable))

        if let notice = fleetImageNotice(), !notice.isEmpty {
            rows.append(
                Row(
                    title: String(localized: "Project images", bundle: .l10n, comment: "Diagnostics row title"),
                    detail: notice, ok: true))
        }

        self.rows = rows
    }
}
