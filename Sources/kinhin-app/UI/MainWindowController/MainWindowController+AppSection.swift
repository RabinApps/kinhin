import AppKit
import SwiftUI

// The App section: launch behavior, updates and files (see `AppSectionView`).
@MainActor
extension MainTabsWindowController {
    func buildAppSection() -> NSView {
        appModel.updateState = delegate?.updateCardState ?? .idle(lastChecked: nil)
        let host = NSHostingView(rootView: AppSectionView(model: appModel))
        // Fills whatever it is pinned into; the cards scroll.
        host.sizingOptions = []
        return host
    }

    /// Shows the update check/download state in the App section's Updates card.
    func renderUpdate(state: UpdateCardState) {
        appModel.updateState = state
    }
}
