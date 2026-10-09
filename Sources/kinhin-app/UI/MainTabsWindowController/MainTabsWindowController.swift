import AppKit
import KinhinKit
import SwiftUI

// MARK: - Main tabs window

/// kinhin's single main window: an `NSWindow` shell hosting `MainTabsView`.
/// The tabs (Fleet, Setup, Advanced), their models and the sheets live in
/// `MainTabsModel` / `WindowModels`; this class forwards window events to the
/// app delegate.
@MainActor
final class MainTabsWindowController: NSWindowController, NSWindowDelegate {
    weak var delegate: MainTabsWindowDelegate? {
        didSet { models.delegate = delegate }
    }

    /// Which tab, section and sheet is showing.
    let tabs: MainTabsModel
    /// The models behind the tabs.
    let models: WindowModels

    /// Open config.yaml from the Setup wizard button row.
    func openConfig() {
        tabs.openConfig()
    }

    init(defaults: UserDefaults = .standard, fleet: FleetController, updates: UpdateController) {
        models = WindowModels(fleet: fleet, updates: updates, prefs: defaults)
        tabs = MainTabsModel(fleet: fleet, models: models)

        let size = NSSize(width: 620, height: 600)
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = String(localized: "kinhin", bundle: .l10n, comment: "Main window title (product name)")
        window.titlebarAppearsTransparent = true
        window.appearance = nil  // follow the system (light & dark)
        window.backgroundColor = .windowBackgroundColor
        let host = NSHostingView(rootView: MainTabsView(model: tabs))
        // Fills the window; each page scrolls its own content.
        host.sizingOptions = []
        window.contentView = host
        window.center()
        window.minSize = NSSize(width: 620, height: 480)
        super.init(window: window)
        window.delegate = self
        tabs.onSetupFinished = { [weak self] in self?.delegate?.setupTabFinished() }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    // MARK: - NSWindowDelegate

    func windowWillClose(_ notification: Notification) {
        delegate?.mainTabsWindowWillClose()
    }
}
