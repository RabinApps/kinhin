import KinhinKit
import SwiftUI

/// The Fleet tab: fleet controls, live status, VM rows, current jobs, and the
/// Logs and Diagnostics buttons. State lives in `FleetModel`.
struct FleetView: View {
    let model: FleetModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 6) {
                Text("○  kinhin").font(.system(size: 22, weight: .bold))
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
            }

            // Only the actions that apply: Start when stopped; Stop and
            // Pause/Resume when running. While a start/stop is in flight its
            // button shows progress and every fleet control disables.
            HStack(spacing: 8) {
                if model.running {
                    if model.pendingAction == .stop {
                        Button {
                        } label: {
                            HStack(spacing: 4) {
                                ProgressView().controlSize(.small)
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
                            ProgressView().controlSize(.small)
                            Text("Start")
                        }
                    }
                    .accessibilityLabel("Starting the fleet")
                } else {
                    Button("Start") { model.startClicked() }
                        .accessibilityLabel("Start the fleet")
                }
            }

            if let note = model.pausedAutoResumeNote {
                Text(note)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }

            VStack(alignment: .leading, spacing: 6) {
                SectionHeader("VMs")
                ScrollView {
                    VStack(alignment: .leading, spacing: 4) {
                        if model.records.isEmpty { secondary("No VMs — the fleet is idle.") }
                        ForEach(model.records, id: \.id) { vmRow($0) }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .containerRelativeFrame(.vertical) { height, _ in height * 0.30 }
            }

            VStack(alignment: .leading, spacing: 6) {
                SectionHeader("Current jobs")
                VStack(alignment: .leading, spacing: 3) {
                    if model.working.isEmpty { secondary("No jobs running.") }
                    ForEach(model.working, id: \.id) { secondary(model.jobLine(for: $0), mono: true) }
                }
                .padding(.leading, 4)
            }

            Spacer(minLength: 0)
            HStack(spacing: 8) {
                Button("Logs…") { model.onShowLogs() }
                Button("Diagnostics…") { model.onShowDiagnostics() }
            }
        }
        .padding(.horizontal, 20)
        .padding(.top, 8)
        .padding(.bottom, 14)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func vmRow(_ record: VMRecord) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 1) {
                Text(model.title(for: record)).font(.system(size: 11, design: .monospaced))
                Text(model.detail(for: record))
                    .font(.system(size: 10))
                    .foregroundStyle(record.error != nil ? StatusStyle.error.color : StatusStyle.secondary.color)
            }
            Spacer(minLength: 12)
            Button("Delete") { model.deleteClicked(record.id) }
                .controlSize(.small)
                .accessibilityLabel("Delete \(record.id)")
        }
        .padding(.horizontal, 4)
        .frame(minHeight: 30)
    }

    private func secondary(_ text: String, mono: Bool = false) -> some View {
        Text(text)
            .font(mono ? .system(size: 11, design: .monospaced) : .system(size: 11))
            .foregroundStyle(.secondary)
    }
}
