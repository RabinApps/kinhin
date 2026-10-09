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
        isDaemonInstalled
            ? String(localized: "Uninstall daemon…", bundle: .l10n, comment: "Settings → App button")
            : String(localized: "Install daemon…", bundle: .l10n, comment: "Settings → App button")
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
        runDaemonCommand(
            "install",
            progressLine: String(
                localized: "Installing the daemon…", bundle: .l10n, comment: "Settings → App daemon progress line"))
    }

    /// Removes the daemon LaunchAgent (`kinhin daemon uninstall`) and stops it.
    func uninstallDaemon() {
        runDaemonCommand(
            "uninstall",
            progressLine: String(
                localized: "Uninstalling the daemon…", bundle: .l10n, comment: "Settings → App daemon progress line"))
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
                        String(
                            localized:
                                "couldn't find the kinhin CLI — install it with scripts/install.sh, then try again (a debug build alone can't install the daemon)",
                            bundle: .l10n, comment: "Settings → App daemon error; the script path stays verbatim"),
                    style: .error)
                return
            }
            let result = try await shell.run([kinhin, "daemon", subcommand], cwd: nil, timeout: 60)
            guard result.succeeded, let line = result.stdout.split(separator: "\n").last.map(String.init) else {
                let message =
                    result.stderr.split(separator: "\n").last.map(String.init)
                    ?? (subcommand == "install"
                        ? String(
                            localized: "`kinhin daemon install` failed", bundle: .l10n,
                            comment: "Settings → App daemon error; the backticked command stays verbatim")
                        : String(
                            localized: "`kinhin daemon uninstall` failed", bundle: .l10n,
                            comment: "Settings → App daemon error; the backticked command stays verbatim"))
                daemonLine = StatusLine(text: message, style: .error)
                return
            }
            daemonLine = StatusLine(text: line, style: .ok)
        } catch {
            daemonLine = StatusLine(
                text: subcommand == "install"
                    ? String(
                        localized: "install failed — \(error.localizedDescription)", bundle: .l10n,
                        comment: "Settings → App daemon error; %@ is the reason")
                    : String(
                        localized: "uninstall failed — \(error.localizedDescription)", bundle: .l10n,
                        comment: "Settings → App daemon error; %@ is the reason"),
                style: .error)
            return
        }
        // The controller sees the new plist / daemon state on its next poll,
        // but the user is looking right now: refresh immediately.
        await fleetController?.refresh()
        fleetController?.detectStaleDaemonPlist()
    }

    // MARK: - Reset

    /// "Reset kinhin…": scope pick, then the exact plan, then a typed
    /// `reset` — three gates before the irreversible wipe runs (the plan and
    /// the typed word are the double confirmation). Every gate and the wipe
    /// itself are injectable so tests drive the whole flow without a modal or
    /// real state.
    @ObservationIgnored var chooseResetScope: () -> ResetScope? = {
        AlertKit.chooseResetScope(
            title: String(localized: "Reset kinhin", bundle: .l10n, comment: "Reset alert title"),
            message:
                String(
                    localized:
                        "Pick what to erase. The next screen lists exactly what will be deleted — this cannot be undone.",
                    bundle: .l10n, comment: "Reset alert body"))
    }
    @ObservationIgnored var confirmResetPlan: (ResetPlan) -> Bool = { plan in
        AlertKit.confirm(
            title: String(
                localized: "Reset kinhin — \(plan.scope.label)?", bundle: .l10n,
                comment: "Reset confirmation title; %@ names what will be erased"),
            message: plan.describe(),
            confirmTitle: String(localized: "Continue", bundle: .l10n, comment: "Reset confirmation button"),
            style: .critical,
            destructive: true)
    }
    @ObservationIgnored var confirmResetWord: () -> Bool = {
        AlertKit.confirmWithTypedWord(
            title: String(
                localized: "Type reset to confirm", bundle: .l10n,
                comment: "Final reset alert title; the word `reset` is what the user must type"),
            message:
                String(
                    localized:
                        "kinhin will permanently delete everything listed above. There is no undo and nothing is kept.",
                    bundle: .l10n, comment: "Final reset alert body"),
            word: "reset",
            confirmTitle: String(localized: "Erase", bundle: .l10n, comment: "Final reset alert destructive button"))
    }
    /// Builds the plan (reads only). Injectable so tests never touch real state.
    @ObservationIgnored var resetPlanner: (ResetScope) async -> ResetPlan = {
        await ResetEverything.plan(scope: $0)
    }
    /// Runs the wipe. Injectable ditto.
    @ObservationIgnored var resetRunner: (ResetPlan) async throws -> [String] = {
        try await ResetEverything.execute($0)
    }
    /// Called after a successful reset, so the app can clear the login item
    /// and re-bootstrap (the wizard reappears when the config was erased).
    @ObservationIgnored var onResetFinished: (ResetScope) -> Void = { _ in }

    /// A reset is in flight (the button disables).
    private(set) var resetBusy = false
    /// The last thing the reset said (progress, success, failure).
    private(set) var resetLine = StatusLine(text: "")

    /// The card's entry point: pick a scope, then confirm twice. The busy
    /// state is set synchronously (before the Task), so a fast second click
    /// is ignored and observers never see a window where a reset is running
    /// but the card still looks idle.
    func resetClicked() {
        guard !resetBusy else { return }
        guard let scope = chooseResetScope() else { return }
        resetBusy = true
        resetLine = StatusLine(
            text: String(
                localized: "Preparing the reset…", bundle: .l10n, comment: "Settings → App reset progress line"))
        Task { await runReset(scope) }
    }

    private func runReset(_ scope: ResetScope) async {
        defer { resetBusy = false }
        do {
            let plan = await resetPlanner(scope)
            guard confirmResetPlan(plan) else {
                resetLine = StatusLine(text: "")
                return
            }
            guard confirmResetWord() else {
                resetLine = StatusLine(text: "")
                return
            }
            // The app's own fleet must stop before the wipe: the core only
            // stops a daemon over RPC, never this process's in-process engine.
            // Nothing running (or a command in flight) is fine — the wipe's
            // stop-before-delete catches a survivor.
            if scope != .config {
                // Best-effort: the wipe below handles leftovers.
                try? await fleetController?.perform(.stop)
            }
            resetLine = StatusLine(
                text: String(
                    localized: "Resetting — deleting files, tokens and VMs…", bundle: .l10n,
                    comment: "Settings → App reset progress line"))
            let report = try await resetRunner(plan)
            if scope.includesConfig {
                // Preferences belong to the app, not the wipe core (the CLI
                // has none): clear them in the injected suite and re-read.
                AppPreferences.reset(in: prefs)
                launchMode = AppPreferences.launchMode(in: prefs)
                launchAtLogin = AppPreferences.launchAtLogin(in: prefs)
                autoStartFleet = AppPreferences.autoStartFleet(in: prefs)
            }
            resetLine = StatusLine(text: report.joined(separator: " · "), style: .ok)
            onResetFinished(scope)
        } catch {
            resetLine = StatusLine(
                text: String(
                    localized: "reset failed — \(error.localizedDescription)", bundle: .l10n,
                    comment: "Settings → App reset error; %@ is the reason"), style: .error)
        }
    }

    // MARK: - Updates

    /// What the update card says, and whether its button can be pressed.
    var updateText: String {
        let current = kinhinVersion.current
        switch updateState {
        case .idle(let lastChecked):
            if let stamp = Self.stamp(lastChecked) {
                return String(
                    localized: "kinhin \(current) — last checked \(stamp)", bundle: .l10n,
                    comment: "Settings → App update status; the version, then the date of the last check")
            }
            return String(
                localized: "kinhin \(current)", bundle: .l10n,
                comment: "Settings → App update status; %@ is the version")
        case .checking:
            return String(
                localized: "kinhin \(current) — checking…", bundle: .l10n,
                comment: "Settings → App update status; %@ is the version")
        case .upToDate(let lastChecked):
            if let stamp = Self.stamp(lastChecked) {
                return String(
                    localized: "kinhin \(current) is up to date — last checked \(stamp)", bundle: .l10n,
                    comment: "Settings → App update status; the version, then the date of the last check")
            }
            return String(
                localized: "kinhin \(current) is up to date", bundle: .l10n,
                comment: "Settings → App update status; %@ is the version")
        case .available(let newVersion):
            return String(
                localized: "Update available — kinhin \(newVersion) (you have \(current)).", bundle: .l10n,
                comment: "Settings → App update status; the new version, then the installed one")
        case .downloading(let name):
            return String(
                localized: "Downloading \(name)…", bundle: .l10n,
                comment: "Settings → App update status; %@ is the DMG file name")
        case .failed(let message):
            return String(
                localized: "Update check failed: \(message)", bundle: .l10n,
                comment: "Settings → App update status; %@ is the reason")
        }
    }

    /// The card's button: download when a release is waiting, else check.
    func updateButtonClicked() { updates.checkOrDownload() }

    var updateButtonTitle: String {
        if case .available = updateState {
            return String(localized: "Download…", bundle: .l10n, comment: "Settings → App button")
        }
        return String(localized: "Check for Updates…", bundle: .l10n, comment: "Settings → App button")
    }

    var updateButtonEnabled: Bool {
        switch updateState {
        case .checking, .downloading: return false
        default: return true
        }
    }

    /// The localized date of the last check, or nil when there was none yet.
    private static func stamp(_ date: Date?) -> String? {
        guard let date, date > .distantPast else { return nil }
        return date.formatted(date: .abbreviated, time: .shortened)
    }
}
