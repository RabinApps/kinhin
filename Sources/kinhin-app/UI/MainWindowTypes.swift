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

// MARK: - Sections

/// The main window's sections, in sidebar order. Fleet is the day-to-day view; the rest are where the fleet is
/// configured and inspected. First-run setup is not a section: while it is unfinished the window shows only the
/// wizard, with no sidebar (`MainTabsModel.isGatedBySetup`).
enum MainSection: String, CaseIterable {
    case fleet
    case runtimes
    case accounts
    case toolchains
    case diagnostics
    case settings

    /// The SF Symbol shown beside the section in the sidebar (the same names the design uses).
    var symbol: String {
        switch self {
        case .fleet: return "server.rack"
        case .runtimes: return "cpu"
        case .accounts: return "person.2"
        case .toolchains: return "wrench.and.screwdriver"
        case .diagnostics: return "stethoscope"
        case .settings: return "gearshape"
        }
    }

    var label: String {
        switch self {
        case .fleet: return String(localized: "Fleet", bundle: .l10n, comment: "Sidebar section title")
        case .runtimes: return String(localized: "Runtimes", bundle: .l10n, comment: "Sidebar section title")
        case .accounts: return String(localized: "Accounts", bundle: .l10n, comment: "Sidebar section title")
        case .toolchains: return String(localized: "Toolchains", bundle: .l10n, comment: "Sidebar section title")
        case .diagnostics: return String(localized: "Diagnostics", bundle: .l10n, comment: "Sidebar section title")
        case .settings: return String(localized: "Settings", bundle: .l10n, comment: "Sidebar section title")
        }
    }
}

/// The sub-sections of Diagnostics: the health report, the logs, benchmarks, containers, and the tools that open the
/// Test Workflow and Make a Video sheets.
enum DiagnosticsPane: String, CaseIterable {
    case health
    case logs
    case benchmarks
    case containers
    case tools

    var label: String {
        switch self {
        case .health: return String(localized: "Health", bundle: .l10n, comment: "Diagnostics sub-section title")
        case .logs: return String(localized: "Logs", bundle: .l10n, comment: "Diagnostics sub-section title")
        case .benchmarks:
            return String(localized: "Benchmarks", bundle: .l10n, comment: "Diagnostics sub-section title")
        case .containers:
            return String(localized: "Containers", bundle: .l10n, comment: "Diagnostics sub-section title")
        case .tools: return String(localized: "Tools", bundle: .l10n, comment: "Diagnostics sub-section title")
        }
    }
}

// MARK: - Window delegate

/// What the main window still needs from the app: the process-level
/// concerns (activation policy, login item, window lifecycle, engine
/// bootstrap). Fleet actions go through `FleetController` instead.
@MainActor
protocol MainTabsWindowDelegate: AnyObject {
    func openLogsFolder()
    func launchModeChanged(_ mode: LaunchMode)
    /// The Settings toggle changed: apply it. Throws `LaunchAtLoginError` when the system refused.
    func launchAtLoginChanged(_ enabled: Bool) throws
    func mainTabsWindowWillClose()
    /// Setup finished (its Start Fleet was pressed): re-bootstrap the engine.
    func setupTabFinished()
    /// Open config.yaml (the Setup wizard's button row, Settings → Files).
    func openConfig()
    /// "Reset kinhin…" finished wiping (Settings): clear the login item
    /// for config-scoped resets and re-bootstrap (the wizard reappears when
    /// the config was erased).
    func resetFinished(scope: ResetScope)
}

// MARK: - Update card state

/// Where the self-update check stands, rendered by Settings.
enum UpdateCardState: Equatable {
    case idle(lastChecked: Date?)
    case checking
    case upToDate(lastChecked: Date?)
    case available(version: String)
    case failed(String)
}
