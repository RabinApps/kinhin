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
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.leading, 4)
            .padding(.top, 4)
        }
    }
}
