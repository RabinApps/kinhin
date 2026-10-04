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

    /// Non-nil when a LaunchAgent plist exists but its binary is missing.
    /// Set from the fleet controller; cleared when the plist is removed or
    /// the binary reappears.
    @ObservationIgnored var fleetController: FleetController?

    var daemonNotice: String? {
        fleetController?.staleDaemonPlist
    }

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

    // MARK: - Daemon mode

    /// Runs `kinhin daemon install` / `uninstall`. Injectable so tests never
    /// spawn a real CLI.
    @ObservationIgnored var daemonShell: ShellRunning = Shell()

    /// A daemon install/uninstall is in flight (the button disables).
    private(set) var daemonBusy = false
    /// The last thing the daemon action said (progress, success, failure).
    private(set) var daemonLine = StatusLine(text: "")
    /// The in-flight daemon command, so it can be cancelled.
    @ObservationIgnored private var daemonTask: Task<Void, Never>?

    /// Whether a daemon LaunchAgent is installed.
    var isDaemonInstalled: Bool { Daemon.agentPlistURL != nil }

    /// Whether the daemon (not an in-process engine) is serving this Mac.
    var isDaemonRunning: Bool {
        guard let backend = fleetController?.backend else { return false }
        if case .daemon = backend { return true }
        return false
    }

    /// The card's button: uninstall when a daemon is installed, else install.
    var daemonToggleButtonTitle: String {
        isDaemonInstalled ? "Uninstall daemon…" : "Install daemon…"
    }

    /// The card's one-click action: installs when no daemon is installed,
    /// uninstalls otherwise. Title and action both derive from
    /// `isDaemonInstalled`, so they cannot disagree.
    func toggleDaemon() {
        if isDaemonInstalled {
            uninstallDaemon()
        } else {
            installDaemon()
        }
    }

    /// Installs the daemon LaunchAgent (`kinhin daemon install`) and starts it.
    /// A debug build refuses (the LaunchAgent must point at a release binary);
    /// the CLI's answer surfaces in `daemonLine` rather than failing silently.
    func installDaemon() {
        runDaemonCommand("install", progressLine: "Installing the daemon…")
    }

    /// Removes the daemon LaunchAgent (`kinhin daemon uninstall`) and stops it.
    func uninstallDaemon() {
        runDaemonCommand("uninstall", progressLine: "Uninstalling the daemon…")
    }

    /// Runs one `kinhin daemon` subcommand off the main thread and reports
    /// the outcome in `daemonLine`.
    private func runDaemonCommand(_ subcommand: String, progressLine: String) {
        guard !daemonBusy else { return }
        daemonBusy = true
        daemonLine = StatusLine(text: progressLine)
        daemonTask = Task { [weak self] in
            await self?.finishDaemonCommand(subcommand)
        }
    }

    /// Cancels the in-flight daemon command. A killed install/uninstall can
    /// leave the LaunchAgent half-configured; the stale-plist notice picks
    /// that up (and re-running the command repairs it).
    func cancelDaemonAction() {
        daemonTask?.cancel()
    }

    private func finishDaemonCommand(_ subcommand: String) async {
        defer { daemonBusy = false }
        guard !Task.isCancelled else { return }
        let shell = daemonShell
        do {
            guard let kinhin = Paths.findExecutable(named: "kinhin") else {
                daemonLine = StatusLine(
                    text:
                        "couldn't find the kinhin CLI — install it with scripts/install.sh, then try again (a debug build alone can't install the daemon)",
                    style: .error)
                return
            }
            let result = try await shell.run([kinhin, "daemon", subcommand], cwd: nil, timeout: 60)
            guard result.succeeded, let line = result.stdout.split(separator: "\n").last.map(String.init) else {
                let message =
                    result.stderr.split(separator: "\n").last.map(String.init)
                    ?? "`kinhin daemon \(subcommand)` failed"
                daemonLine = StatusLine(text: message, style: .error)
                return
            }
            daemonLine = StatusLine(text: line, style: .ok)
        } catch {
            daemonLine = StatusLine(text: "\(subcommand) failed — \(error.localizedDescription)", style: .error)
            return
        }
        // The controller sees the new plist / daemon state on its next poll,
        // but the user is looking right now: refresh immediately.
        await fleetController?.refresh()
        fleetController?.detectStaleDaemonPlist()
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
