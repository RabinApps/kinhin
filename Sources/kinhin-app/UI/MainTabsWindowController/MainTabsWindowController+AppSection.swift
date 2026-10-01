import AppKit
import SwiftUI

// The App section: launch behavior, updates and files (see `AppSectionView`).
@MainActor
extension MainTabsWindowController {
    func buildAppSection() -> NSView {
        let host = NSHostingView(rootView: AppSectionView(model: appModel))
        // Fills whatever it is pinned into; the cards scroll.
        host.sizingOptions = []
        return host
    }
}
