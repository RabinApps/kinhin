import KinhinKit
import Observation
import SwiftUI

/// The Diagnostics section's Health pane: a Health card (one inset row per check, a Re-check button) over the Healing
/// card. It fills the pane and scrolls on its own.
struct DiagnosticsView: View {
    let model: DiagnosticsModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Spacing.lg) {
                Card(
                    title: Text("Health"), subtitle: Text(verbatim: model.status), layout: .fill,
                    trailing: {
                        Button("Re-check") { Task { await model.load() } }
                            .controlSize(.small)
                            .disabled(model.isChecking)
                            .accessibilityIdentifier("diagnostics-recheck")
                    },
                    content: {
                        VStack(spacing: Spacing.sm) {
                            ForEach(model.rows) { row in
                                DiagnosticsRow(row: row)
                            }
                        }
                    })
                if let healing = model.healing {
                    HealingSectionView(
                        healing: healing, busyIDs: model.busyHealingIDs,
                        approve: { model.approveHealing(id: $0) },
                        dismiss: { model.dismissHealing(id: $0) })
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.bottom, Spacing.md)
        }
    }
}

/// One check: a dot (green ok, red not), the title, the selectable detail (so fix commands can be copied) and an
/// orange warning line.
private struct DiagnosticsRow: View {
    let row: DiagnosticsModel.Row

    var body: some View {
        InsetRow(
            alignment: .firstTextBaseline,
            leading: { StatusDot(style: row.ok ? .ok : .error) },
            content: {
                VStack(alignment: .leading, spacing: Spacing.xxs) {
                    Text(verbatim: row.title).typeStyle(.body).fontWeight(.semibold)
                    Text(verbatim: row.detail)
                        .typeStyle(.caption)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                    if let warning = row.warning {
                        Text(verbatim: "⚠ \(warning)")
                            .typeStyle(.caption)
                            .fontWeight(.medium)
                            .foregroundStyle(StatusStyle.warn.color)
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        )
    }
}

#Preview("Health pane") {
    DiagnosticsView(model: DiagnosticsModel.previewModel()).padding(Spacing.lg).frame(width: 640, height: 420)
}
