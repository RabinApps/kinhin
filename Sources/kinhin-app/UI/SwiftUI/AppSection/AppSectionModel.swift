import Foundation
import KinhinKit
import Observation

/// State and actions behind Advanced → App: launch behavior, update check and
/// the config/log files. Preferences persist through `AppPreferences`; the
/// update card reads `UpdateController`; the window controller wires the
/// callbacks to its delegate.
@MainActor
@Observable
final class AppSectionModel {
    /// Where the section persists prefs. The real app uses .standard; tests
    /// inject a scratch suite.
    @ObservationIgnored let prefs: UserDefaults

    @ObservationIgnored var onLaunchModeChanged: (LaunchMode) -> Void = { _ in }
    @ObservationIgnored var onLaunchAtLoginChanged: (Bool) -> Void = { _ in }
    @ObservationIgnored var onOpenLogs: () -> Void = {}

    private(set) var launchMode: LaunchMode
    private(set) var launchAtLogin: Bool
    private(set) var autoStartFleet: Bool
    @ObservationIgnored let updates: UpdateController
    var updateState: UpdateCardState { updates.updateCardState }

    /// The login item only works from the installed kinhin.app.
    var showsLoginHint: Bool { !LaunchAtLoginService.isBundled }

    init(prefs: UserDefaults, updates: UpdateController) {
        self.prefs = prefs
        self.updates = updates
        launchMode = AppPreferences.launchMode(in: prefs)
        launchAtLogin = AppPreferences.launchAtLogin(in: prefs)
        autoStartFleet = AppPreferences.autoStartFleet(in: prefs)
    }

    // MARK: - Launch

    /// Applies a launch mode, persists it and tells the app.
    func setLaunchMode(_ mode: LaunchMode) {
        launchMode = mode
        Log.info("app", "launch mode set to \(mode.rawValue)")
        AppPreferences.setLaunchMode(mode, in: prefs)
        onLaunchModeChanged(mode)
    }

    func setLaunchAtLogin(_ enabled: Bool) {
        launchAtLogin = enabled
        AppPreferences.setLaunchAtLogin(enabled, in: prefs)
        onLaunchAtLoginChanged(enabled)
    }

    func setAutoStartFleet(_ enabled: Bool) {
        autoStartFleet = enabled
        AppPreferences.setAutoStartFleet(enabled, in: prefs)
    }

    // MARK: - Updates

    /// What the update card says, and whether its button can be pressed.
    var updateText: String {
        let version = "kinhin \(kinhinVersion.current)"
        switch updateState {
        case .idle(let lastChecked): return Self.lastCheckedText(version: version, lastChecked)
        case .checking: return "\(version) — checking…"
        case .upToDate(let lastChecked):
            return Self.lastCheckedText(version: "\(version) is up to date", lastChecked)
        case .available(let newVersion):
            return "Update available — kinhin \(newVersion) (you have \(kinhinVersion.current))."
        case .downloading(let name): return "Downloading \(name)…"
        case .failed(let message): return "Update check failed: \(message)"
        }
    }

    /// The card's button: download when a release is waiting, else check.
    func updateButtonClicked() { updates.checkOrDownload() }

    var updateButtonTitle: String {
        if case .available = updateState { return "Download…" }
        return "Check for Updates…"
    }

    var updateButtonEnabled: Bool {
        switch updateState {
        case .checking, .downloading: return false
        default: return true
        }
    }

    private static func lastCheckedText(version: String, _ date: Date?) -> String {
        guard let date, date > .distantPast else { return version }
        return "\(version) — last checked \(date.formatted(date: .abbreviated, time: .shortened))"
    }
}
