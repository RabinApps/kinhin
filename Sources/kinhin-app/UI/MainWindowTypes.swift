import AppKit
import KinhinKit

// MARK: - Pure decisions (unit-tested)

/// Decides which activation policy the app runs with. Kept as a pure,
/// unit-testable function so MainWindowTests can pin the normal-app behavior
/// without launching anything.
@MainActor
func activationPolicy(showingMainWindow: Bool, launchMode: LaunchMode) -> NSApplication.ActivationPolicy {
    // Any visible main window makes kinhin a real app (Dock icon + app menu).
    // In menu-bar-only mode there is never a window, so the policy stays
    // accessory; in the other two modes the app always presents a window
    // (at launch, or as soon as the user opens one).
    if showingMainWindow { return .regular }
    return launchMode.showsMainWindowWithoutBeingVisible ? .regular : .accessory
}

extension LaunchMode {
    /// Modes whose identity is the main window stay `.regular` even while the
    /// window is closed, so re-opening it (Dock, login item) feels like a
    /// normal app rather than flipping the process persona back and forth.
    var showsMainWindowWithoutBeingVisible: Bool { self != .menuBarOnly }
}

/// Whether closing the main window should terminate the app: only in
/// main-window-only mode, where the window is the whole app and a living
/// invisible process would be a zombie.
@MainActor
func shouldQuitOnMainWindowClose(launchMode: LaunchMode) -> Bool {
    launchMode == .mainWindowOnly
}

// MARK: - Tabs

/// The main window's tabs. Fleet is the day-to-day view, Setup is where an
/// account and this Mac are connected (a guided wizard on first run), and
/// Advanced holds everything you rarely touch.
enum MainTab: String, CaseIterable {
    case fleet
    case detail
    case setup
    case advanced

    var label: String {
        switch self {
        case .fleet: return "Fleet"
        case .detail: return "Detail"
        case .setup: return "Setup"
        case .advanced: return "Advanced"
        }
    }
}

/// Sub-sections of the Advanced tab.
enum AdvancedSection: String, CaseIterable {
    case accounts
    case capacity
    case routing
    case containers
    case toolchains
    case app

    var label: String {
        switch self {
        case .accounts: return "Accounts"
        case .capacity: return "Capacity"
        case .routing: return "Routing"
        case .containers: return "Containers"
        case .toolchains: return "Toolchains"
        case .app: return "App"
        }
    }
}

// MARK: - Tab delegate

/// What the tabbed window still needs from the app: the process-level
/// concerns (activation policy, login item, window lifecycle, engine
/// bootstrap). Fleet actions go through `FleetController` instead.
@MainActor
protocol MainTabsWindowDelegate: AnyObject {
    func openLogsFolder()
    func launchModeChanged(_ mode: LaunchMode)
    func launchAtLoginChanged(_ enabled: Bool)
    func mainTabsWindowWillClose()
    /// Setup finished (its Start Fleet was pressed): re-bootstrap the engine.
    func setupTabFinished()
    /// Open config.yaml from the Setup wizard button row.
    func openConfig()
    /// "Reset kinhin…" finished wiping (App section): clear the login item
    /// for config-scoped resets and re-bootstrap (the wizard reappears when
    /// the config was erased).
    func resetFinished(scope: ResetScope)
}

// MARK: - Update card state

/// Where the update check/download stands, rendered by Settings → App.
enum UpdateCardState: Equatable {
    case idle(lastChecked: Date?)
    case checking
    case upToDate(lastChecked: Date?)
    case available(version: String)
    case downloading(name: String)
    case failed(String)
}
