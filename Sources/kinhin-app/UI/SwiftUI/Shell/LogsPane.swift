import SwiftUI

/// The Logs pane: one card holding the searchable log and, under it, an Open logs folder button. The ring buffer is
/// re-read every second while the pane is up.
struct LogsPane: View {
    let model: LogsModel
    let openFolder: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.md) {
            Text("Logs").typeStyle(.emphasis)
            LogsView(model: model)
            HStack {
                Button("Open logs folder", action: openFolder)
                    .controlSize(.small)
                    .accessibilityIdentifier("open-logs-folder")
                Spacer()
            }
        }
        .padding(Spacing.lg)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .formSurface(cornerRadius: Radius.xl)
        .task {
            while !Task.isCancelled {
                do {
                    try await Task.sleep(for: .seconds(1))
                } catch {
                    return
                }
                model.refresh()
            }
        }
    }
}

#Preview("Logs pane") {
    LogsPane(model: LogsModel(), openFolder: {})
        .padding(Spacing.lg)
        .frame(width: 720, height: 360)
}
