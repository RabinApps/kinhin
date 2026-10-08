import KinhinKit
import SwiftUI

/// The missing-Homebrew sheet: kinhin installs the tool with Homebrew, so
/// without it the user gets Homebrew, downloads the tool by hand (when one
/// exists), or cancels.
struct MissingBrewSheet: View {
    let offer: MissingBrewOffer
    let onGetBrew: () -> Void
    let onDownload: () -> Void
    let onCancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Homebrew isn't installed", systemImage: "exclamationmark.triangle.fill")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(StatusStyle.warn.color)
            Text(
                "kinhin installs \(offer.tool.title) with Homebrew. Install Homebrew first, or download \(offer.tool.title) yourself."
            )
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                if offer.manualURL != nil {
                    Button("Download \(offer.tool.title)", action: onDownload)
                }
                Button("Cancel", action: onCancel)
                    .keyboardShortcut(.cancelAction)
                Button("Get Homebrew", action: onGetBrew)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(16)
        .frame(width: 360, alignment: .leading)
    }
}
