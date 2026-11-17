import KinhinKit
import SwiftUI

/// The install-confirmation sheet: states exactly what will run, lets the
/// user pick a method when there are several, and offers to copy the command
/// instead of running it.
struct InstallConfirmationSheet: View {
    let offer: InstallOffer
    let onConfirm: (InstallOption) -> Void
    let onCopy: (InstallOption) -> Void
    let onCancel: () -> Void

    @State private var selectedID: String

    init(
        offer: InstallOffer, onConfirm: @escaping (InstallOption) -> Void,
        onCopy: @escaping (InstallOption) -> Void, onCancel: @escaping () -> Void
    ) {
        self.offer = offer
        self.onConfirm = onConfirm
        self.onCopy = onCopy
        self.onCancel = onCancel
        _selectedID = State(initialValue: offer.options.first?.id ?? "")
    }

    private var selected: InstallOption? {
        offer.options.first { $0.id == selectedID }
    }

    var body: some View {
        SheetScaffold(verbatimTitle: String(localized: "Install \(offer.tool.title)?", bundle: .l10n), width: 480) {
            VStack(alignment: .leading, spacing: Spacing.md) {
                HintText(
                    "kinhin will run this with Homebrew. It may take several minutes, and some installers ask for your password or need a first launch afterwards."
                )
                VStack(alignment: .leading, spacing: Spacing.sm) {
                    ForEach(offer.options) { option in
                        optionRow(option)
                    }
                }
                if let option = selected {
                    HintText(verbatim: option.detail)
                }
            }
        } footer: {
            SheetConfirmFooter(
                "Install",
                confirm: { if let option = selected { onConfirm(option) } },
                cancel: onCancel
            ) {
                Button("Copy Command") {
                    if let option = selected { onCopy(option) }
                }
            }
        }
    }

    /// One install method: a checkbox-style choice with its command line beside it.
    private func optionRow(_ option: InstallOption) -> some View {
        Button {
            selectedID = option.id
        } label: {
            HStack(spacing: Spacing.md) {
                Image(systemName: option.id == selectedID ? "checkmark.square.fill" : "square")
                    .foregroundStyle(option.id == selectedID ? Palette.accent : Palette.secondaryText)
                Text(verbatim: option.title).typeStyle(.body)
                Text(verbatim: option.commandLine)
                    .typeStyle(.caption)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .lineLimit(2)
                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(option.id == selectedID ? .isSelected : [])
        .accessibilityIdentifier("install-method-\(option.id)")
    }
}
