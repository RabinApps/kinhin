import SwiftUI

/// The bar pinned to the bottom of the Runtimes page: what is waiting ("2 unapplied changes — Apply restarts the
/// fleet if needed."), what went wrong ("Not applied — …") or that it worked ("Applied ✓"), with Revert and Apply.
/// They cover the staged edits only: fleet capacity and every Keep idle floor. Routes, switches, pools and labels
/// save as you make them.
struct CapacityApplyBar: View {
    let model: CapacityModel

    var body: some View {
        let status = model.status
        HStack(spacing: Spacing.md) {
            StatusText(verbatim: status.text, style: status.style)
            Spacer(minLength: Spacing.sm)
            Button("Revert") { model.revert() }
                .disabled(!model.hasPendingChanges)
                .accessibilityIdentifier("capacity-revert")
            Button("Apply") { model.applyPending() }
                .keyboardShortcut(.defaultAction)
                .disabled(!model.canApply)
                .accessibilityIdentifier("capacity-apply")
        }
        .padding(.horizontal, Spacing.lg)
        .padding(.vertical, Spacing.sm + 2)
        .background(RoundedRectangle(cornerRadius: Radius.xl).fill(Palette.surface))
        .overlay(
            RoundedRectangle(cornerRadius: Radius.xl)
                .strokeBorder(status.text.isEmpty ? Palette.separator : status.style.fill, lineWidth: 1)
        )
    }
}

#Preview("Apply bar") {
    CapacityApplyBar(model: CapacityModel())
        .padding(Spacing.lg)
        .frame(width: 600)
}
