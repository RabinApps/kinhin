import SwiftUI

/// What a long action on this Mac is doing (installing a tool, baking an image) or just said ("Base image saved.
/// Rebuild the image for it to take effect."), with Cancel while it runs. One strip for the page: the runtime cards
/// start the actions and this shows their progress.
struct MacBusyStrip: View {
    let model: MacToolsModel

    var body: some View {
        if model.busy || !model.busyLine.text.isEmpty {
            HStack(alignment: .top, spacing: Spacing.sm) {
                if model.busy { ProgressView().controlSize(.small).accessibilityLabel("Working") }
                StatusText(verbatim: model.busyLine.text, style: model.busyLine.style)
                    .textSelection(.enabled)
                Spacer(minLength: Spacing.sm)
                if model.busy {
                    Button("Cancel") { model.cancelRunning() }
                        .controlSize(.small)
                        .accessibilityIdentifier("mac-busy-cancel")
                }
            }
            .padding(.horizontal, Spacing.lg)
            .padding(.vertical, Spacing.sm + 2)
            .frame(maxWidth: .infinity, alignment: .leading)
            .formSurface(cornerRadius: Radius.xl)
        }
    }
}
