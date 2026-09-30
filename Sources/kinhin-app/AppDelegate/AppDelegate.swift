import AppKit
import KinhinKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    var statusItem: NSStatusItem?
    var menu: NSMenu?
    // The single main window hosts every tab (Fleet, Setup, Advanced). Hold the controller, not just its window:
    // NSControl.target is unretained, so the controller must stay alive
    // for the tab buttons to work.
    var mainController: MainTabsWindowController?

    /// Latest fleet status from the refresh poll — the Fleet tab renders it
    /// on open so it never shows stale "Loading…" content.
    var lastStatus: FleetStatus?

    /// A fleet start/stop command is in flight (menu item, Fleet tab, or App
    /// Intent). The status item shows "Starting…"/"Stopping…", and the
    /// Start/Stop menu items disable until the command and its status
    /// refresh complete.
    var pendingFleetAction: FleetAction? {
        didSet {
            guard pendingFleetAction != oldValue else { return }
            apply(status: lastStatus)
            mainController?.fleetModel.setPending(pendingFleetAction)
        }
    }

    /// Set while first-run onboarding is up (or no usable config exists) —
    /// the Setup tab then covers the window at launch.
    var setupIncomplete = false
    /// Tracks the main window's visibility so the activation policy can be
    /// re-evaluated when it opens and closes.
    var isMainWindowVisible = false

    /// Who runs the fleet: nil until setup is complete.
    var backend: FleetBackend?
    /// The in-process engine, when this app runs the fleet itself.
    var engine: FleetEngine? { backend?.engine }
    /// Config-edit push (debounced): a burst of edits flushes once.
    var pendingConfigEdits = false
    var isConfigPushScheduled = false
    private var pollTimer: Timer?
    private var updateTimer: Timer?

    // Update check state
    var lastUpdateCheck: Date?
    var pendingUpdate: UpdateInfo?
    /// Drives the Settings → App update card; every change is pushed to the window.
    var updateCardState: UpdateCardState = .idle(lastChecked: UpdatePreferences.lastCheck) {
        didSet { mainController?.renderUpdate(state: updateCardState) }
    }
    var updateDownloadTask: Task<Void, Never>?
    var updateCheckTask: Task<Void, Never>?
    var updateChecker: UpdateChecker {
        UpdateChecker(repo: UpdatePreferences.repo)
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        Paths.ensureSupportDirectories()
        Log.setLogFile(directory: Paths.logsDirectory)
        installMainMenu()
        let mode = AppPreferences.launchMode
        if mode.showsStatusItem {
            installStatusItem()
        }
        bootstrapEngine()
        autoStartFleetIfEnabled()
        pollTimer = Timer.scheduledTimer(withTimeInterval: 3.0, repeats: true) { [weak self] _ in
            Task { await self?.refresh() }
        }
        Task { await refresh() }
        // Once per day (or on first launch), at most.
        if Date().timeIntervalSince(UpdatePreferences.lastCheck) >= UpdatePreferences.interval {
            checkForUpdates()
        }
        updateTimer = Timer.scheduledTimer(withTimeInterval: 3600.0, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.checkForUpdates()
            }
        }
        // Launch-mode surface selection: the main window opens unless the user
        // chose menu-bar-only or onboarding already took the stage (the
        // window's Setup tab is the launch surface until setup completes).
        if mode.showMainWindowAtLaunch {
            openMainWindow()
        }
        applyActivationPolicy()
    }

    func applicationWillTerminate(_ notification: Notification) {
        Task { await engine?.stop() }
        updateCheckTask?.cancel()
        updateDownloadTask?.cancel()
    }

    // MARK: Activation policy (normal app vs menu bar app)

    /// Syncs the process persona with the current surfaces: a visible main
    /// window (or a launch mode that is defined by the window) makes kinhin
    /// a regular app with a Dock icon and app menu; otherwise it is the
    /// classic accessory menu-bar app.
    func applyActivationPolicy() {
        let policy = activationPolicy(
            showingMainWindow: isMainWindowVisible,
            launchMode: AppPreferences.launchMode
        )
        if NSApp.activationPolicy() != policy {
            NSApp.setActivationPolicy(policy)
            Log.info("app", "activation policy → \(policy == .regular ? "regular" : "accessory")")
        }
    }

    // MARK: Engine wiring

    func bootstrapEngine(reopenSetupOnFailure: Bool = true) {
        // First-run convenience: materialize the starter config (never
        // overwriting). The checklist still asks for a real repo, so this
        // can't mask an unfinished setup.
        if ConfigLoader.createIfMissing() {
            Log.info("app", "first run: wrote starter config at \(Paths.config.path)")
        }
        // Attach to daemon when one is running; otherwise run the engine in-process.
        if RPCClient.isDaemonAlive() {
            backend = .daemon(RPCClient())
            setupIncomplete = false
            Log.info("app", "attaching to running daemon")
        } else if FileManager.default.fileExists(atPath: Paths.config.path),
            // A broken config stays a broken config for the wizard to surface;
            // loading it here is only a fast-path gate for "skip onboarding".
            let cfg = try? ConfigLoader.load(),
            // A template config (placeholder repo, no gitea:) is not a
            // working config — keep onboarding up instead of booting a
            // fleet against "your-org/your-repo".
            ConfigLoader.hasAnyForge(cfg),
            // GitHub PAT, or (Gitea-only config) the Gitea token.
            let pat = engineTokenLoggingFailure(for: cfg),
            // tart, or a Linux runtime (Docker / Apple container) to run on.
            cfg.canRunOnThisHost()
        {
            do {
                backend = .inProcess(try FleetEngine.production(config: cfg, token: pat))
                setupIncomplete = false
                Log.info("app", "no daemon; running engine in-process (not started yet)")
            } catch {
                Log.error("app", "could not build engine: \(error.localizedDescription)")
            }
        } else {
            setupIncomplete = true
            Log.info("app", "setup incomplete — the guided setup opens")
            mainController?.setupIncompleteFlag = true
            if reopenSetupOnFailure { openMainWindow() }
        }
    }

    /// The engine token for launch. A Keychain failure is logged and yields nil,
    /// which routes to the guided setup; its checklist then shows the
    /// "Keychain error" row instead of asking for a token that is already saved.
    private func engineTokenLoggingFailure(for cfg: KinhinConfig) -> String? {
        do {
            return try ConfigLoader.engineToken(for: cfg)
        } catch {
            Log.error("app", "could not read the forge token at launch: \(error.localizedDescription)")
            return nil
        }
    }

    /// Starts the in-process fleet at launch when the user asked for it. A
    /// running daemon owns its own lifecycle, and an incomplete setup has no
    /// engine, so neither is touched.
    func autoStartFleetIfEnabled() {
        guard AppPreferences.autoStartFleet, let engine else { return }
        Log.info("app", "auto-starting the fleet (Settings → App)")
        Task {
            await engine.start()
            await refresh()
        }
    }

    // MARK: Refresh

    func refresh() async {
        // Polled every few seconds (daemon calls run off the main thread): an
        // unreachable or wedged daemon simply reads as "not running" in the
        // status item, so a failure here is expected (status stays nil).
        let status = try? await backend?.status()
        apply(status: status)
    }
}
