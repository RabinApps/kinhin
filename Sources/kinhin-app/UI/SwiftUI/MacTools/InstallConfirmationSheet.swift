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
        VStack(alignment: .leading, spacing: 10) {
            Text("Install \(offer.tool.title)?")
                .font(.system(size: 13, weight: .semibold))
            Text(
                "kinhin will run this with Homebrew. It may take several minutes, and some installers ask for your password or need a first launch afterwards."
            )
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)

            if offer.options.count > 1 {
                Picker("Method", selection: $selectedID) {
                    ForEach(offer.options) { option in
                        Text(option.title).tag(option.id)
                    }
                }
                .labelsHidden()
                .controlSize(.small)
                .accessibilityLabel("Install method")
            }

            if let option = selected {
                Text(option.detail)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Text(option.commandLine)
                    .font(.system(size: 11, design: .monospaced))
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack {
                Spacer()
                if offer.options.count > 1 {
                    Button("Copy Command") {
                        if let option = selected { onCopy(option) }
                    }
                }
                Button("Cancel", action: onCancel)
                    .keyboardShortcut(.cancelAction)
                Button("Install") {
                    if let option = selected { onConfirm(option) }
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(16)
        .frame(width: 340, alignment: .leading)
    }
}
