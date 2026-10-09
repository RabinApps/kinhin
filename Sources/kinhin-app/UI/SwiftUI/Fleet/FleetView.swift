import KinhinKit
import SwiftUI

/// The Fleet tab: the runtime diagram (each runtime's lanes, each live
/// instance one icon-led row — the VM list that used to have a card of its
/// own — or an explicit "idle"), the fleet card (live status and the start/stop
/// controls), current jobs and the queued-work controls — all of them scroll
/// together — over a support row that stays pinned. State lives in
/// `FleetModel`.
struct FleetView: View {
    let model: FleetModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Text("○  kinhin").font(.system(size: 22, weight: .bold))
                if let badge = model.fleetModeBadge {
                    Text(badge)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(.tertiary)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(
                            RoundedRectangle(cornerRadius: 4)
                                .fill(Color(nsColor: .controlBackgroundColor))
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 4)
                                .strokeBorder(Color(nsColor: .separatorColor), lineWidth: 0.5)
                        )
                }
            }

            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    FleetDiagramView(
                        model: model.diagram,
                        placeholder: model.diagramPlaceholder,
                        onOpenPipeline: { model.pipelineClicked($0) },
                        onDelete: { model.deleteClicked($0) }
                    )

                    FormCard(title: "Fleet") {
                        VStack(alignment: .leading, spacing: 6) {
                            if let notice = model.diskPressureNotice {
                                diskPressureBanner(notice)
                            }
                            Text(model.statusLine)
                                .font(.system(size: 12))
                                .foregroundStyle(.secondary)
                                // Ceiling on the shared line: counters, plus the
                                // auto-resume note, queue age, and both per-repo
                                // breakdowns on a paused fleet draining its last jobs.
                                .lineLimit(5)
                            if let notice = model.imageNotice {
                                Text(notice)
                                    .font(.system(size: 11))
                                    .foregroundStyle(.secondary)
                                    .lineLimit(3)
                                    .accessibilityIdentifier("image-notice")
                            }
                            ForEach(model.fleetStatusFooter, id: \.text) { foot in
                                StatusText(verbatim: foot.text, style: foot.style)
                            }
                        }
                        controls
                        if let note = model.pausedAutoResumeNote {
                            Text(note)
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                        }
                    }

                    FormCard(title: "Current jobs") {
                        VStack(alignment: .leading, spacing: 3) {
                            if model.working.isEmpty { secondary(Text("No jobs running.")) }
                            ForEach(model.working, id: \.id) {
                                secondary(Text(verbatim: model.jobLine(for: $0)), mono: true)
                            }
                        }
                    }

                    FormCard(title: "Queued work") {
                        requeueBlock
                    }
                }
            }

            // Pinned below the scroll: the support actions stay reachable no
            // matter how much fleet content is on screen.
            HStack(spacing: 8) {
                Button("Logs…") { model.onShowLogs() }
                Button("Diagnostics…") { model.onShowDiagnostics() }
                Button("Test Workflow…") { model.onShowWorkflowTest() }
            }
        }
        .padding(.horizontal, 20)
        .padding(.top, 8)
        .padding(.bottom, 14)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    /// Only the actions that apply: Start when stopped; Stop and Pause/Resume
    /// when running. While a start/stop is in flight its button shows
    /// progress and every fleet control disables.
    private var controls: some View {
        HStack(spacing: 8) {
            if model.running {
                if model.pendingAction == .stop {
                    Button {
                    } label: {
                        HStack(spacing: 4) {
                            ProgressView().controlSize(.small).accessibilityLabel("Working")
                            Text("Stop")
                        }
                    }
                    .accessibilityLabel("Stopping the fleet")
                } else {
                    Button("Stop") { model.stopClicked() }
                        .accessibilityLabel("Stop the fleet")
                }
                Button(model.pauseTitle) { model.togglePause() }
                    .accessibilityLabel("Pause or resume the fleet")
                    .disabled(model.isBusy)
            } else if model.pendingAction == .start {
                Button {
                } label: {
                    HStack(spacing: 4) {
                        ProgressView().controlSize(.small).accessibilityLabel("Working")
                        Text("Start")
                    }
                }
                .buttonStyle(.borderedProminent)
                .accessibilityLabel("Starting the fleet")
            } else {
                Button("Start") { model.startClicked() }
                    .buttonStyle(.borderedProminent)
                    .accessibilityLabel("Start the fleet")
            }
        }
    }

    /// Per-forge requeue/skip queued: one row per attached forge, with the
    /// org-only scope and the fleet-wide button.
    private var requeueBlock: some View {
        VStack(alignment: .leading, spacing: 6) {
            if model.attachedForges.isEmpty {
                secondary(Text("No forges attached — queue will always be empty."))
            } else {
                ForEach(Array(model.attachedForges.enumerated()), id: \.offset) { _, forge in
                    HStack(spacing: 6) {
                        Picker("", selection: .constant(forge.keys.sorted().first ?? "")) {
                            ForEach(forge.keys.sorted(), id: \.self) { id in Text(id).tag(id) }
                        }
                        .pickerStyle(.menu)
                        .frame(width: 120)
                        .accessibilityLabel("Forge: \(forge.keys.sorted().first ?? "unknown")")
                        Button("Requeue") {
                            let scope = forgeScope(forge)
                            model.requeueQueuedJobs(for: scope ?? .github, forAll: scope == nil)
                        }
                        .disabled(model.isBusy)
                        .accessibilityLabel("Requeue queued jobs on \(forge.keys.sorted().first ?? "unknown")")
                        Button("Skip") {
                            let scope = forgeScope(forge)
                            model.skipQueuedJobs(for: scope ?? .github, forAll: scope == nil)
                        }
                        .disabled(model.isBusy)
                        .accessibilityLabel("Skip queued jobs on \(forge.keys.sorted().first ?? "unknown")")
                    }
                }
            }
        }
    }

    /// True when the forge has no slash in its scope (org-wide); a
    /// single-repo scope (a slash) targets that forge.
    func forgeScope(_ forge: [String: Forge]) -> ForgeID? {
        guard let first = forge.keys.sorted().first, let target = forge[first] else { return nil }
        return target.attributesByRepo ? nil : target.id
    }

    /// Dismissible warning while the engine holds spawns for disk pressure.
    /// Dismissing hides it for the session; it returns only with a new
    /// pressure episode (or a relaunch).
    private func diskPressureBanner(_ notice: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 11))
                .foregroundStyle(StatusStyle.warn.color)
                .accessibilityLabel("Warning")
            Text(notice)
                .font(.system(size: 11))
                .foregroundStyle(StatusStyle.warn.color)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 8)
            Button("Dismiss") { model.dismissDiskPressureNotice() }
                .controlSize(.small)
                .accessibilityLabel("Dismiss the disk pressure warning")
        }
        .padding(8)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(StatusStyle.warn.color.opacity(0.12))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .strokeBorder(StatusStyle.warn.color.opacity(0.5), lineWidth: 1)
        )
        .accessibilityIdentifier("disk-pressure-banner")
    }

    private func secondary(_ text: Text, mono: Bool = false) -> some View {
        text
            .font(mono ? .system(size: 11, design: .monospaced) : .system(size: 11))
            .foregroundStyle(.secondary)
    }
}
