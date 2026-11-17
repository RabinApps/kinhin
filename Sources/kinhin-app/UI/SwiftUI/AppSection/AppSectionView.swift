import AppKit
import KinhinKit
import SwiftUI

/// The Settings page: launch behavior, updates, files, telemetry, alerts, the daemon, reset, feedback and support, as
/// grouped cards in one scroll. State and actions live in `AppSectionModel`, `TelemetryModel` and `AlertsModel`.
struct AppSectionView: View {
    let model: AppSectionModel
    let telemetry: TelemetryModel
    let alerts: AlertsModel
    /// Opens the Support kinhin sheet (the same one the sidebar star opens).
    let openSupport: () -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Spacing.lg) {
                launchCard
                updatesCard
                filesCard
                TelemetryCard(model: telemetry)
                AlertsCard(model: alerts)
                if let notice = model.daemonNotice { Banner(verbatim: notice, kind: .warn) }
                DaemonCard(model: model)
                resetCard
                feedbackCard
                supportCard
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.bottom, Spacing.md)
        }
    }

    // MARK: - Launch

    private var launchCard: some View {
        Card(title: "Launch", layout: .fill) {
            VStack(spacing: Spacing.sm) {
                InsetRow(
                    content: { RowLabel("Show at launch") },
                    trailing: {
                        Picker(
                            "Show at launch",
                            selection: Binding(get: { model.launchMode }, set: { model.setLaunchMode($0) })
                        ) {
                            ForEach(LaunchMode.allCases, id: \.self) { Text(verbatim: $0.label).tag($0) }
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                        .fixedSize()
                        .accessibilityLabel("What kinhin shows at launch")
                    })
                HintText(verbatim: model.launchMode.subtitle)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, Spacing.sm + 2)
                toggleRow(
                    "Launch kinhin at login",
                    isOn: Binding(get: { model.launchAtLogin }, set: { model.setLaunchAtLogin($0) }))
                toggleRow(
                    "Start the fleet when kinhin opens",
                    isOn: Binding(get: { model.autoStartFleet }, set: { model.setAutoStartFleet($0) }))
            }
            if model.showsLoginHint {
                HintText("Applies to the installed kinhin.app — no effect while running unbundled from `swift run`.")
            }
        }
    }

    private func toggleRow(_ title: LocalizedStringKey, isOn: Binding<Bool>) -> some View {
        InsetRow(
            content: { Text(title).typeStyle(.body).fontWeight(.medium) },
            trailing: {
                Toggle(title, isOn: isOn).labelsHidden().toggleStyle(.switch)
            })
    }

    // MARK: - Updates

    private var updatesCard: some View {
        Card(title: "Updates", layout: .fill) {
            InsetRow(
                content: {
                    Text(verbatim: model.updateText)
                        .typeStyle(.body)
                        .fontWeight(.medium)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("update-status")
                },
                trailing: {
                    Button(model.updateButtonTitle) { model.updateButtonClicked() }
                        .disabled(!model.updateButtonEnabled)
                        .accessibilityIdentifier("check-for-updates")
                })
        }
    }

    // MARK: - Files

    private var filesCard: some View {
        Card(
            title: "Files",
            subtitle: "Everything here is saved in config.yaml — open it for settings that have no control.",
            layout: .fill
        ) {
            VStack(spacing: Spacing.sm) {
                InsetRow(
                    content: { Text(verbatim: "config.yaml").typeStyle(.body).fontWeight(.medium) },
                    trailing: {
                        Button("Open config file") { NSWorkspace.shared.open(Paths.config) }
                            .controlSize(.small)
                            .accessibilityIdentifier("open-config-file")
                    })
                InsetRow(
                    content: { Text("Logs").typeStyle(.body).fontWeight(.medium) },
                    trailing: {
                        Button("Open logs folder") { model.onOpenLogs() }
                            .controlSize(.small)
                            .accessibilityIdentifier("open-logs-folder-settings")
                    })
            }
        }
    }

    // MARK: - Reset, feedback, support

    private var resetCard: some View {
        Card(title: "Reset", layout: .fill) {
            InsetRow(
                content: {
                    RowLabel(
                        "Reset kinhin…", detail: "Erase credentials, the daemon, or everything. Three confirmations.")
                },
                trailing: {
                    HStack(spacing: Spacing.sm) {
                        if model.resetBusy { ProgressView().controlSize(.small).accessibilityLabel("Working") }
                        Button("Reset kinhin…", role: .destructive) { model.resetClicked() }
                            .disabled(model.resetBusy)
                            .accessibilityIdentifier("app-reset-button")
                    }
                })
            if !model.resetLine.text.isEmpty {
                StatusText(verbatim: model.resetLine.text, style: model.resetLine.style)
                    .textSelection(.enabled)
                    .accessibilityIdentifier("app-reset-status")
            }
        }
    }

    private var feedbackCard: some View {
        Card(title: "Feedback", layout: .fill) {
            HStack(spacing: Spacing.md) {
                Link(SupportLinks.reportAnIssue.name, destination: SupportLinks.reportAnIssue.url)
                    .accessibilityIdentifier("submit-github-issue")
                HintText("Opens a GitHub issue in your browser.")
            }
        }
    }

    /// One Support card: its button opens the Support kinhin sheet, so the donation text lives only there.
    private var supportCard: some View {
        Card(title: "Support kinhin", subtitle: "kinhin is free and built by one developer.", layout: .fill) {
            HStack(spacing: Spacing.md) {
                Button("Support kinhin…", action: openSupport)
                    .accessibilityIdentifier("settings-support")
                HintText("Opens the same sheet as the sidebar star.")
            }
        }
    }
}
