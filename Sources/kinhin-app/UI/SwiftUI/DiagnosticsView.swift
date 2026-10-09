import KinhinKit
import Observation
import SwiftUI

/// The Diagnostics sheet content: header, one card per check, Close.
struct DiagnosticsView: View {
    static let size = CGSize(width: 560, height: 520)

    let model: DiagnosticsModel
    let onClose: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text("🩺  Diagnostics").font(.system(size: 18, weight: .bold))
                StatusText(verbatim: model.status)
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
