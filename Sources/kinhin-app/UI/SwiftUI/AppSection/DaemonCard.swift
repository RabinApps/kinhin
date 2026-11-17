import KinhinKit
import SwiftUI

/// Settings → Daemon mode: whether the LaunchAgent is installed and serving, the Install/Uninstall button with its
/// progress line (and Cancel while it works) and the error it ends with. State and actions live in `AppSectionModel`.
struct DaemonCard: View {
    let model: AppSectionModel

    var body: some View {
        Card(
            title: "Daemon mode",
            subtitle: "Run the fleet inside this app, or in a background LaunchAgent that survives restarts.",
            layout: .fill
        ) {
            VStack(spacing: Spacing.sm) {
                InsetRow(
                    content: { Text("Installed").typeStyle(.body).fontWeight(.medium) },
                    trailing: {
                        Text(model.isDaemonInstalled ? "Yes" : "No")
                            .typeStyle(.body)
                            .foregroundStyle(
                                model.isDaemonInstalled ? StatusStyle.ok.color : StatusStyle.secondary.color)
                    })
                InsetRow(
                    content: { Text("Running").typeStyle(.body).fontWeight(.medium) },
                    trailing: {
                        Text(model.isDaemonRunning ? "Serving the fleet" : "Not serving")
                            .typeStyle(.body)
                            .foregroundStyle(model.isDaemonRunning ? StatusStyle.ok.color : StatusStyle.secondary.color)
                    })
            }
            HStack(alignment: .firstTextBaseline, spacing: Spacing.md) {
                Button(model.daemonToggleButtonTitle) { model.toggleDaemon() }
                    .disabled(model.daemonBusy)
                    .accessibilityIdentifier("app-daemon-toggle")
                if model.daemonBusy {
                    ProgressView().controlSize(.small).accessibilityLabel("Working")
                    StatusText(verbatim: model.daemonLine.text, style: model.daemonLine.style)
                        .textSelection(.enabled)
                }
                Spacer(minLength: 0)
                if model.daemonBusy {
                    Button("Cancel") { model.cancelDaemonAction() }
                        .accessibilityIdentifier("app-daemon-cancel")
                }
            }
            .accessibilityIdentifier(model.daemonBusy ? "app-daemon-busy" : "app-daemon-actions")
            if !model.daemonBusy, !model.daemonLine.text.isEmpty {
                StatusText(verbatim: model.daemonLine.text, style: model.daemonLine.style)
                    .textSelection(.enabled)
                    .accessibilityIdentifier("app-daemon-status")
            }
        }
    }
}
