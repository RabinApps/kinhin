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

// MARK: - Launch at login

/// The system's login-item registration for this app (`SMAppService.mainApp` in production). A seam so tests
/// never touch the real service registration.
protocol LoginItemRegistering {
    var status: SMAppService.Status { get }
    func register() throws
    func unregister() throws
}

extension SMAppService: LoginItemRegistering {}

/// Why the login item could not be set as asked.
enum LaunchAtLoginError: LocalizedError, Equatable {
    /// Registered, but macOS will not open kinhin at login until the user approves it in System Settings.
    case requiresApproval
    case registerFailed(String)
    case unregisterFailed(String)

    /// Whether the login item is still registered after the failure: the toggle's real state.
    var leavesRegistered: Bool {
        switch self {
        case .requiresApproval, .unregisterFailed: return true
        case .registerFailed: return false
        }
    }

    var errorDescription: String? {
        switch self {
        case .requiresApproval:
            return String(
                localized:
                    "kinhin needs your approval to open at login. Approve it in System Settings → General → Login Items.",
                bundle: .l10n,
                comment: "Launch-at-login alert message; keep kinhin and the System Settings path verbatim")
        case .registerFailed(let reason):
            return String(
                localized: "kinhin could not be added to your login items: \(reason)", bundle: .l10n,
                comment: "Launch-at-login alert message; %@ is the system's error")
        case .unregisterFailed(let reason):
            return String(
                localized: "kinhin could not be removed from your login items: \(reason)", bundle: .l10n,
                comment: "Launch-at-login alert message; %@ is the system's error")
        }
    }
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

    /// The alert title for a failed apply.
    static var alertTitle: String {
        String(localized: "Launch at login", bundle: .l10n, comment: "Alert title for a launch-at-login failure")
    }

    /// Applies the stored preference. Throws `LaunchAtLoginError` when the
    /// system refuses or still needs the user's approval; unbundled, the
    /// preference is only stored (the Settings hint says so).
    static func apply(
        enabled: Bool, service: any LoginItemRegistering = SMAppService.mainApp, isBundled: Bool = isBundled
    ) throws {
        guard isBundled else {
            Log.info("app", "launch-at-login: not a bundled app; preference stored only")
            return
        }
        if enabled {
            do {
                if service.status != .enabled {
                    try service.register()
                }
            } catch {
                Log.error("app", "launch-at-login register failed: \(error.localizedDescription)")
                // A login item the user switched off in System Settings fails to register until they approve it.
                if service.status == .requiresApproval { throw LaunchAtLoginError.requiresApproval }
                throw LaunchAtLoginError.registerFailed(error.localizedDescription)
            }
            if service.status == .requiresApproval {
                Log.warn("app", "launch-at-login: registered; waiting for approval in System Settings")
                throw LaunchAtLoginError.requiresApproval
            }
            Log.info("app", "launch-at-login: registered main-app login item")
        } else {
            do {
                if service.status == .enabled || service.status == .requiresApproval {
                    try service.unregister()
                }
            } catch {
                Log.error("app", "launch-at-login unregister failed: \(error.localizedDescription)")
                throw LaunchAtLoginError.unregisterFailed(error.localizedDescription)
            }
            Log.info("app", "launch-at-login: removed main-app login item")
        }
    }
}
