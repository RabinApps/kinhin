import AppKit
import KinhinKit
import SwiftUI

/// Advanced → App: launch behavior, updates and files. State and actions live
/// in `AppSectionModel`.
struct AppSectionView: View {
    let model: AppSectionModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                FormCard(title: "Launch") {
                    Picker(
                        "Show at launch",
                        selection: Binding(get: { model.launchMode }, set: { model.setLaunchMode($0) })
                    ) {
                        ForEach(LaunchMode.allCases, id: \.self) { Text($0.label) }
                    }
                    .accessibilityLabel("What kinhin shows at launch")
                    HintText(model.launchMode.subtitle)
                    Toggle(
                        "Launch kinhin at login",
                        isOn: Binding(get: { model.launchAtLogin }, set: { model.setLaunchAtLogin($0) }))
                    Toggle(
                        "Start the fleet when kinhin opens",
                        isOn: Binding(get: { model.autoStartFleet }, set: { model.setAutoStartFleet($0) }))
                    if model.showsLoginHint {
                        Text(
                            "Applies to the installed kinhin.app — no effect while running unbundled from `swift run`."
                        )
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                        .fixedSize(horizontal: false, vertical: true)
                    }
                }
                FormCard(title: "Updates") {
                    Button(model.updateButtonTitle) { model.updateButtonClicked() }
                        .disabled(!model.updateButtonEnabled)
                        .accessibilityIdentifier("check-for-updates")
                    HintText(model.updateText).accessibilityIdentifier("update-status")
                }
                
                FormCard(
                    title: "Files",
                    subtitle:
                        "Everything above is saved in config.yaml — open it for settings that have no control here."
                ) {
                    HStack {
                        Button("Open config file") { NSWorkspace.shared.open(Paths.config) }
                            .accessibilityIdentifier("open-config-file")
                        Button("Open logs folder") { model.onOpenLogs() }
                    }
                }
                if let notice = model.daemonNotice {
                    FormCard(title: "Daemon") {
                        Text(notice)
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                FormCard(
                    title: "Daemon mode",
                    subtitle:
                        "The fleet can run inside this app (in-process) or in a background LaunchAgent that survives app restarts and reboots."
                ) {
                    HStack {
                        VStack(alignment: .leading, spacing: 4) {
                            statusRow(
                                title: "Installed",
                                text: model.isDaemonInstalled ? "Installed" : "Not installed",
                                style: model.isDaemonInstalled ? .ok : .secondary)
                            statusRow(
                                title: "Running",
                                text: model.isDaemonRunning ? "Serving the fleet" : "Not serving",
                                style: model.isDaemonRunning ? .ok : .secondary)
                        }
                        Spacer(minLength: 0)
                        Button(model.daemonToggleButtonTitle) { model.toggleDaemon() }
                            .disabled(model.daemonBusy)
                            .accessibilityIdentifier("app-daemon-toggle")
                    }
                    if model.daemonBusy || !model.daemonLine.text.isEmpty {
                        HStack(alignment: .top, spacing: 8) {
                            if model.daemonBusy { ProgressView().controlSize(.small) }
                            StatusText(text: model.daemonLine.text, style: model.daemonLine.style)
                                .textSelection(.enabled)
                            if model.daemonBusy {
                                Spacer(minLength: 0)
                                Button("Cancel") { model.cancelDaemonAction() }
                                    .controlSize(.small)
                                    .accessibilityIdentifier("app-daemon-cancel")
                            }
                        }
                        .accessibilityElement(children: .combine)
                        .accessibilityIdentifier("app-daemon-busy")
                    }
                }

                FormCard(
                    title: "Reset",
                    subtitle:
                        "Erase kinhin's local state — you choose how much: credentials only, the daemon, or everything. This cannot be undone."
                ) {
                    HStack {
                        Button("Reset kinhin…", role: .destructive) { model.resetClicked() }
                            .disabled(model.resetBusy)
                            .accessibilityIdentifier("app-reset-button")
                        if model.resetBusy { ProgressView().controlSize(.small) }
                    }
                    if !model.resetLine.text.isEmpty {
                        StatusText(text: model.resetLine.text, style: model.resetLine.style)
                            .textSelection(.enabled)
                            .accessibilityIdentifier("app-reset-status")
                    }
                }

                FormCard(
                    title: "Support kinhin",
                    subtitle: "kinhin is free and built by one developer. Donations and sponsors keep it going."
                ) {
                    HStack {
                        ForEach(SupportLinks.donate, id: \.name) { channel in
                            Link(channel.name, destination: channel.url)
                        }
                        Link(SupportLinks.becomeASponsor.name, destination: SupportLinks.becomeASponsor.url)
                    }
                    if !SupportLinks.sponsors.isEmpty {
                        HStack(spacing: 4) {
                            HintText("Sponsored by")
                            ForEach(SupportLinks.sponsors, id: \.name) { Link($0.name, destination: $0.url) }
                        }
                    }
                    HStack(spacing: 4) {
                        HintText("More from Rabin Apps:")
                        ForEach(SupportLinks.projects, id: \.name) { Link($0.name, destination: $0.url) }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.leading, 4)
            .padding(.top, 4)
        }
    }

    /// One label/value pair of the daemon card (Installed, Running).
    private func statusRow(title: String, text: String, style: StatusStyle) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.system(size: 12, weight: .semibold))
            StatusText(text: text, style: style)
        }
    }
}
