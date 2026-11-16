import KinhinKit
import Observation
import SwiftUI

/// The Diagnostics section's Health pane: the report's status line, one card per
/// check, and the healing card. It fills the pane and scrolls on its own.
struct DiagnosticsView: View {
    let model: DiagnosticsModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            StatusText(verbatim: model.status)
            ScrollView {
                VStack(spacing: 8) {
                    ForEach(model.rows) { row in
                        DiagnosticsRow(row: row)
                    }
                    if let healing = model.healing {
                        HealingSectionView(
                            healing: healing, busyIDs: model.busyHealingIDs,
                            approve: { model.approveHealing(id: $0) },
                            dismiss: { model.dismissHealing(id: $0) })
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
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
                Text(verbatim: row.title).font(.system(size: 13, weight: .semibold))
                // Selectable so fix commands can be copied.
                Text(verbatim: row.detail)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                if let warning = row.warning {
                    Text(verbatim: "⚠ \(warning)")
                        .font(.system(size: 11))
                        .foregroundStyle(StatusStyle.warn.color)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(width: 500, alignment: .leading)
        .formSurface(cornerRadius: 8)
    }
}
