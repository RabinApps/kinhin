import KinhinKit
import SwiftUI

// MARK: - Linux runtime choice sheet

/// The sheet the "This Mac" form opens from "Set up Linux jobs…": the three-way
/// comparison (`docs/runtimes.md#choosing-a-linux-runtime`) plus, for each option,
/// the install methods this Mac can use. Nothing writes config here — the chosen
/// option is handed back to `MacToolsModel.applyLinuxRuntime`, which installs it
/// and then flips the matching toggle so the form keeps the choice.
@MainActor
struct LinuxRuntimeSetupSheet: View {
    let offer: LinuxRuntimeSetup.Offer
    let model: MacToolsModel
    @State private var choosing: LinuxRuntimeSetup?
    @State private var installing: Bool = false

    private var options: [LinuxRuntimeSetup] {
        guard let tool = offer.tool else {
            return LinuxRuntimeSetup.offeredOptions(on: HostFacts.current())
        }
        return LinuxRuntimeSetup.offeredOptions(on: HostFacts.current()).filter { $0.tool == tool }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            choices
            Spacer(minLength: 0)
            footer
        }
        .padding(.horizontal, 24)
        .padding(.bottom, 24)
        .frame(width: 560)
        .onAppear { choosing = firstChoice }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Choose a Linux runtime")
                .font(.system(size: 22, weight: .bold))
            Text("Pick how this Mac runs Linux jobs. You can change this later in the Setup tab.")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .lineLimit(2)
        }
    }

    private var firstChoice: LinuxRuntimeSetup? {
        options.first
    }

    private var choices: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach([LinuxRuntimeSetup.appleContainer, .docker, .tartLinux], id: \.id) { option in
                LinuxRuntimeChoiceRow(
                    option: option,
                    highlighted: choosing == option,
                    installed: option.isInstalled,
                    disabled: !options.contains(option) || installing
                )
                .onTapGesture {
                    guard !installing else { return }
                    choosing = option
                }
            }
        }
    }

    private var footer: some View {
        HStack(spacing: 12) {
            Spacer(minLength: 0)
            Button("Cancel") { offer.onConfirm(nil) }
                .controlSize(.small)
            if let choice = choosing {
                Button(choice.startInstallButtonTitle) {
                    installing = true
                    Task { await choice.startInstall(model: model) }
                }
                .controlSize(.small)
                .disabled(installing)
                .accessibilityIdentifier("linux-setup-confirm-\(choice.id)")
            }
        }
    }
}

// MARK: - One choice row

private struct LinuxRuntimeChoiceRow: View {
    let option: LinuxRuntimeSetup
    let highlighted: Bool
    let installed: Bool
    let disabled: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                roundedBox(for: option)
                Text(option.displayName)
                    .font(.system(size: 13, weight: .semibold))
                MaturityBadge(option.maturity)
                Spacer(minLength: 0)
                if installed {
                    Text("installed ✓")
                        .font(.system(size: 11))
                        .foregroundStyle(StatusStyle.ok.color)
                }
            }
            Text(option.summary)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .lineLimit(2)
            HStack(spacing: 6) {
                Text(option.prerequisite)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                Spacer(minLength: 0)
                if let blocked = option.unavailableReason, !highlighted {
                    Text(blocked)
                        .font(.system(size: 11))
                        .foregroundStyle(StatusStyle.warn.color)
                }
            }
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(highlighted ? Color(nsColor: .selectedContentBackgroundColor) : Color.clear)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(
                    highlighted ? Color(nsColor: .controlAccentColor) : Color(nsColor: .separatorColor),
                    lineWidth: 1
                )
        )
        .opacity(disabled && !highlighted ? 0.5 : 1)
    }

    private func roundedBox(for option: LinuxRuntimeSetup) -> some View {
        let symbol: String
        let color: Color
        switch option {
        case .appleContainer:
            symbol = "shippingbox.fill"; color = .orange
        case .docker:
            symbol = "cube.fill"; color = .blue
        case .tartLinux:
            symbol = "desktopcomputer"; color = .purple
        }
        return Image(systemName: symbol)
            .font(.system(size: 14))
            .foregroundStyle(.white)
            .frame(width: 24, height: 24)
            .background(color)
            .clipShape(RoundedRectangle(cornerRadius: 5))
    }
}

// MARK: - Private helpers

private extension LinuxRuntimeSetup {
    var isInstalled: Bool {
        guard let tool else { return false }
        return tool.isInstalled
    }

    var unavailableReason: String? {
        let host = HostFacts.current()
        return LinuxRuntimeSetup.unavailableReason(for: self, on: host)
    }

    var startInstallButtonTitle: String {
        if isInstalled {
            switch self {
            case .appleContainer:
                return String(
                    localized: "Start service & use it", bundle: .l10n, comment: "Button of the Linux runtime sheet")
            case .docker:
                return String(localized: "Use it", bundle: .l10n, comment: "Button of the Linux runtime sheet")
            case .tartLinux:
                return String(localized: "Use it", bundle: .l10n, comment: "Button of the Linux runtime sheet")
            }
        }
        return String(localized: "Install & use it", bundle: .l10n, comment: "Button of the Linux runtime sheet")
    }

    @discardableResult
    func startInstall(model: MacToolsModel) async {
        guard let tool else { return }
        await model.install(tool)
    }
}
