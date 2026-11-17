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
        SheetScaffold(title: "Homebrew isn't installed", width: 420) {
            HintText(
                "kinhin installs \(offer.tool.title) with Homebrew. Install Homebrew first, or download \(offer.tool.title) yourself."
            )
        } footer: {
            HStack {
                Spacer()
                if offer.manualURL != nil {
                    Button("Download \(offer.tool.title)", action: onDownload)
                }
                Button("Get Homebrew", action: onGetBrew)
                    .keyboardShortcut(.defaultAction)
                Button("Cancel", action: onCancel)
                    .keyboardShortcut(.cancelAction)
            }
        }
    }
}
