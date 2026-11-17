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
        SheetScaffold(title: "Choose a Linux runtime", width: 700) {
            VStack(alignment: .leading, spacing: Spacing.md) {
                HintText("Pick how this Mac runs Linux jobs. You can change this later in Runtimes.")
                choices
            }
        } footer: {
            footer
        }
        .onAppear { choosing = firstChoice }
    }

    private var firstChoice: LinuxRuntimeSetup? {
        options.first
    }

    private var choices: some View {
        HStack(alignment: .top, spacing: Spacing.md) {
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
        HStack(spacing: Spacing.md) {
            Spacer(minLength: 0)
            Button("Cancel") { offer.onConfirm(nil) }
                .keyboardShortcut(.cancelAction)
            if let choice = choosing {
                Button(choice.startInstallButtonTitle) {
                    installing = true
                    Task { await choice.startInstall(model: model) }
                }
                .keyboardShortcut(.defaultAction)
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
        VStack(alignment: .leading, spacing: Spacing.xs) {
            HStack(spacing: Spacing.sm) {
                Text(option.displayName).typeStyle(.emphasis)
                Spacer(minLength: 0)
                MaturityBadge(option.maturity)
            }
            HintText(verbatim: option.summary)
            HintText(verbatim: option.prerequisite)
            if installed {
                Chip("installed ✓", tone: .ok)
            }
            if let blocked = option.unavailableReason, !highlighted {
                StatusText(verbatim: blocked, style: .warn)
            }
            Spacer(minLength: 0)
        }
        .padding(Spacing.md)
        .frame(maxWidth: .infinity, minHeight: 130, alignment: .topLeading)
        .background(
            RoundedRectangle(cornerRadius: Radius.lg)
                .fill(highlighted ? Palette.accent.opacity(0.12) : Palette.surface)
        )
        .overlay(
            RoundedRectangle(cornerRadius: Radius.lg)
                .strokeBorder(highlighted ? Palette.accent : Palette.separator, lineWidth: highlighted ? 2 : 1)
        )
        .opacity(disabled && !highlighted ? 0.5 : 1)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(highlighted ? .isSelected : [])
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

    func startInstall(model: MacToolsModel) async {
        guard let tool else { return }
        await model.install(tool)
    }
}
