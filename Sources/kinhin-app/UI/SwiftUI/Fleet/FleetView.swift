import KinhinKit
import SwiftUI

/// The Fleet page (`design/exports/fleet.png`): the header (state chip, engine mode, Start / Stop / Pause / Resume),
/// the banners, the status block, one card per runtime with its instances, the current jobs and the queued-work
/// controls. The header stays put; everything under it scrolls. State lives in `FleetModel`.
struct FleetView: View {
    let model: FleetModel

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.lg) {
            header
            ScrollView {
                VStack(alignment: .leading, spacing: Spacing.md) {
                    ForEach(model.bannerRows) { row in banner(row) }
                    if model.showsOnlyNote {
                        pageNoteCard
                    } else {
                        if let note = model.pausedAutoResumeNote { HintText(verbatim: note) }
                        if model.showsStatusBlock { statusBlock }
                        if let notice = model.imageNotice {
                            HintText(verbatim: notice)
                                .accessibilityIdentifier("image-notice")
                        }
                        if let stopped = model.stoppedNote { noteCard(stopped) }
                        FleetDiagramView(
                            model: model.diagram,
                            placeholder: model.diagramPlaceholder,
                            onOpenPipeline: { model.pipelineClicked($0) },
                            onDelete: { model.deleteClicked($0) }
                        )
                        if model.status?.running == true {
                            currentJobs
                            queuedWork
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.bottom, Spacing.md)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: Spacing.sm) {
            Text("Fleet")
                .typeStyle(.display)
                .accessibilityAddTraits(.isHeader)
            let chip = model.stateChip
            Chip(verbatim: chip.text, tone: chip.tone)
                .accessibilityIdentifier("fleet-state-chip")
            Chip(verbatim: model.fleetModeBadge ?? "—", tone: .neutral)
                .accessibilityIdentifier("fleet-mode-badge")
            Spacer(minLength: Spacing.md)
            controls
        }
    }

    /// Only the actions that apply (`FleetControls`): Start when stopped; Stop and Pause/Resume when running. While a
    /// start/stop is in flight its button shows progress and every fleet control disables.
    private var controls: some View {
        let controls = model.controls
        return HStack(spacing: Spacing.sm) {
            if controls.isVisible(.pauseResume) {
                controlButton(.pauseResume, controls, prominent: controls.isResume) { model.togglePause() }
            }
            if controls.isVisible(.stop) { controlButton(.stop, controls) { model.stopClicked() } }
            if controls.isVisible(.start) { controlButton(.start, controls, prominent: true) { model.startClicked() } }
        }
    }

    private func controlButton(
        _ control: FleetControls.Control, _ controls: FleetControls, prominent: Bool = false,
        action: @escaping () -> Void
    ) -> some View {
        let title =
            control == .start && model.presenter.state == .needsSetup
            ? String(localized: "Set up…", bundle: .l10n, comment: "Fleet button that opens first-run setup")
            : controls.title(control)
        let button = Button(action: action) {
            HStack(spacing: Spacing.xs) {
                if controls.showsProgress(control) {
                    ProgressView().controlSize(.small).accessibilityLabel("Working")
                }
                Text(verbatim: title)
            }
        }
        .disabled(!controls.isEnabled(control))
        .accessibilityLabel(controls.accessibilityLabel(control))
        return Group {
            if prominent { button.buttonStyle(.borderedProminent) } else { button }
        }
    }

    // MARK: - Banners and status

    private func banner(_ row: FleetModel.BannerRow) -> some View {
        Group {
            if row.kind == .diskPressure {
                Banner(verbatim: row.text, kind: row.banner)
                    .action("Dismiss", label: "Dismiss the disk pressure warning") { model.dismissDiskPressureNotice() }
                    .accessibilityIdentifier("disk-pressure-banner")
            } else {
                Banner(verbatim: row.text, kind: row.banner)
            }
        }
    }

    private var statusBlock: some View {
        let lines = model.statusLines
        return Card(layout: .fill) {
            VStack(alignment: .leading, spacing: Spacing.xs) {
                if let headline = lines.first {
                    Text(verbatim: headline).typeStyle(.emphasis)
                }
                ForEach(Array(lines.dropFirst().enumerated()), id: \.offset) { _, line in
                    HintText(verbatim: line)
                }
            }
            .accessibilityElement(children: .combine)
        }
        .accessibilityIdentifier("fleet-status-card")
    }

    private var pageNoteCard: some View {
        Group {
            if let note = model.pageNote { noteCard(note) }
        }
    }

    private func noteCard(_ text: String) -> some View {
        Card(layout: .fill) { StatusText(verbatim: text) }
            .accessibilityIdentifier("fleet-note-card")
    }

    // MARK: - Current jobs

    private var currentJobs: some View {
        Card(title: "Current jobs", layout: .fill) {
            if model.working.isEmpty {
                StatusText(text: "No jobs running.")
            } else {
                VStack(alignment: .leading, spacing: Spacing.sm) {
                    ForEach(model.working, id: \.id) { row in
                        HStack(spacing: Spacing.sm) {
                            Text(verbatim: model.jobTitle(for: row)).typeStyle(.body)
                            Spacer(minLength: Spacing.md)
                            Text(verbatim: model.jobLocation(for: row))
                                .typeStyle(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .padding(.horizontal, Spacing.md - 2)
                        .padding(.vertical, Spacing.sm)
                        .background(RoundedRectangle(cornerRadius: Radius.md).fill(Palette.grouped))
                        .accessibilityElement(children: .combine)
                    }
                }
            }
        }
        .accessibilityIdentifier("fleet-current-jobs")
    }

    // MARK: - Queued work

    private var queuedWork: some View {
        Card(
            title: "Queued work", subtitle: "Counts per forge; actions apply to every queued job on that forge",
            layout: .fill
        ) {
            if model.isDaemonMode {
                VStack(alignment: .leading, spacing: Spacing.xs) {
                    Text(verbatim: model.queueSummary).typeStyle(.emphasis)
                    StatusText(
                        text:
                            "Queue actions need forge access — not available in daemon mode. Use kinhin CLI or switch to in-process engine.",
                        style: .warn)
                }
            } else if model.forgeRows.isEmpty {
                StatusText(text: "No forges attached — queue will always be empty.")
            } else {
                VStack(alignment: .leading, spacing: Spacing.sm) {
                    Text(verbatim: model.queueSummary).typeStyle(.emphasis)
                    ForEach(model.forgeRows) { forgeRow($0) }
                }
            }
        }
        .accessibilityIdentifier("fleet-queued-work")
    }

    private func forgeRow(_ row: FleetModel.ForgeRow) -> some View {
        HStack(spacing: Spacing.sm) {
            Text(verbatim: row.label).typeStyle(.body)
            Spacer(minLength: Spacing.md)
            Button("Requeue") { model.requeue(row) }
                .disabled(model.isBusy)
                .accessibilityLabel("Requeue queued jobs on \(row.label)")
            Button("Skip") { model.skip(row) }
                .disabled(model.isBusy)
                .accessibilityLabel("Skip queued jobs on \(row.label)")
        }
        .controlSize(.small)
        .padding(.horizontal, Spacing.md - 2)
        .padding(.vertical, Spacing.sm)
        .background(RoundedRectangle(cornerRadius: Radius.md).fill(Palette.grouped))
    }
}
