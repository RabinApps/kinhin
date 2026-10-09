import Foundation
import KinhinKit
import ServiceManagement

/// Which surfaces the app shows: a normal main window, the menu bar item,
/// or both. Persisted in UserDefaults so the choice survives relaunches —
/// the same policy as the update-check stamp (UpdatePreferences).
enum LaunchMode: String, CaseIterable, Equatable {
    /// Normal app: main window opens at launch, menu bar item stays.
    case mainWindowAndMenuBar
    /// Today's classic menu-bar-app behavior.
    case menuBarOnly
    /// No menu bar item: the main window is the whole app, and closing it
    /// quits.
    case mainWindowOnly
}

extension LaunchMode {
    var label: String {
        switch self {
        case .mainWindowAndMenuBar:
            return String(
                localized: "Main window + menu bar", bundle: .l10n,
                comment: "Launch-mode picker option in Settings → App")
        case .mainWindowOnly:
            return String(
                localized: "Main window only", bundle: .l10n, comment: "Launch-mode picker option in Settings → App")
        case .menuBarOnly:
            return String(
                localized: "Menu bar only", bundle: .l10n, comment: "Launch-mode picker option in Settings → App")
        }
    }

    var subtitle: String {
        switch self {
        case .mainWindowAndMenuBar:
            return String(
                localized: "Opens a fleet window and keeps the ○ in the menu bar.", bundle: .l10n,
                comment: "Hint under the launch-mode picker; ○ is the menu bar glyph")
        case .mainWindowOnly:
            return String(
                localized: "A normal app — no menu bar item; closing the window quits kinhin.", bundle: .l10n,
                comment: "Hint under the launch-mode picker")
        case .menuBarOnly:
            return String(
                localized: "The classic tray app — open the window any time from the menu.", bundle: .l10n,
                comment: "Hint under the launch-mode picker")
        }
    }

    var showMainWindowAtLaunch: Bool { self != .menuBarOnly }
    var showsStatusItem: Bool { self != .mainWindowOnly }
}

/// App-surface preferences (launch mode, launch at login) backed by
/// UserDefaults, with injectable suite accessors so tests exercise the
/// round-trip against a scratch defaults suite instead of the app's real
/// defaults (mirrors UpdatePreferences).
enum AppPreferences {
    static let launchModeKey = "kinhin.launchMode"
    static let launchAtLoginKey = "kinhin.launchAtLogin"
    static let autoStartFleetKey = "kinhin.autoStartFleet"

    /// The effective default: a normal app. Existing installs upgrading see
    /// the same behavior plus the new window, since the mode also controls
    /// the window at launch.
    static var defaultMode: LaunchMode { .mainWindowAndMenuBar }

    static var launchMode: LaunchMode {
        get { launchMode(in: .standard) }
        set { setLaunchMode(newValue, in: .standard) }
    }

    static var launchAtLogin: Bool {
        get { launchAtLogin(in: .standard) }
        set { setLaunchAtLogin(newValue, in: .standard) }
    }

    /// Start the fleet whenever kinhin opens. Off by default so an upgrade
    /// never starts spawning VMs on its own; the onboarding wizard asks.
    static var autoStartFleet: Bool {
        get { autoStartFleet(in: .standard) }
        set { setAutoStartFleet(newValue, in: .standard) }
    }

    static func launchMode(in defaults: UserDefaults) -> LaunchMode {
        guard let raw = defaults.string(forKey: launchModeKey),
            let mode = LaunchMode(rawValue: raw)
        else {
            return defaultMode
        }
        return mode
    }

    static func setLaunchMode(_ mode: LaunchMode, in defaults: UserDefaults) {
        defaults.set(mode.rawValue, forKey: launchModeKey)
    }

    static func launchAtLogin(in defaults: UserDefaults) -> Bool {
        defaults.bool(forKey: launchAtLoginKey)
    }

    static func setLaunchAtLogin(_ enabled: Bool, in defaults: UserDefaults) {
        defaults.set(enabled, forKey: launchAtLoginKey)
    }

    static func autoStartFleet(in defaults: UserDefaults) -> Bool {
        defaults.bool(forKey: autoStartFleetKey)
    }

    static func setAutoStartFleet(_ enabled: Bool, in defaults: UserDefaults) {
        defaults.set(enabled, forKey: autoStartFleetKey)
    }

    /// Erases every kinhin preference — the config-reset scope of "Reset
    /// kinhin…" clears these along with the config file and the tokens, so
    /// the next launch behaves like a first run. The update-check stamp is
    /// included (it is kinhin state, not a user choice to preserve).
    static func reset(in defaults: UserDefaults) {
        for key in [launchModeKey, launchAtLoginKey, autoStartFleetKey, updateCheckKey] {
            defaults.removeObject(forKey: key)
        }
    }

    private static let updateCheckKey = "kinhin.lastUpdateCheck"
}

/// Applies/removes the login item through SMAppService. Kept out of the
/// preference store so tests can exercise the decision logic without
/// touching the system's real service registration.
enum LaunchAtLoginService {
    /// Registering the running binary as a main-app login item requires a
    /// bundled app (a real Info.plist); `swift run` builds a bare executable,
    /// so there the toggle is stored but has nothing to apply to.
    static var isBundled: Bool {
        Bundle.main.bundlePath.hasSuffix(".app")
    }

    /// Applies the stored preference. Errors are logged, not surfaced — the
    /// checkbox state stays as the user set it and the next launch retries.
    @discardableResult
    static func apply(enabled: Bool) -> Bool {
        guard isBundled else {
            Log.info("app", "launch-at-login: not a bundled app; preference stored only")
            return false
        }
        do {
            if enabled {
                if SMAppService.mainApp.status != .enabled {
                    try SMAppService.mainApp.register()
                }
                Log.info("app", "launch-at-login: registered main-app login item")
            } else {
                if SMAppService.mainApp.status == .enabled {
                    try SMAppService.mainApp.unregister()
                }
                Log.info("app", "launch-at-login: removed main-app login item")
            }
            return true
        } catch {
            Log.error("app", "launch-at-login apply failed: \(error.localizedDescription)")
            return false
        }
    }

    static var currentStatus: Bool {
        guard isBundled else { return false }
        return SMAppService.mainApp.status == .enabled
    }
}
