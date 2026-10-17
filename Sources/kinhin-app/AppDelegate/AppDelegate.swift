import AppKit
import KinhinKit
import Observation

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    var statusItem: NSStatusItem?
    var menu: NSMenu?
    // The single main window hosts every tab (Fleet, Setup, Advanced). Hold the controller, not just its window:
    // NSControl.target is unretained, so the controller must stay alive
    // for the tab buttons to work.
    var mainController: MainTabsWindowController?

    /// Fleet state, polling, pending actions and config push (see AppState/).
    let fleet = FleetController()
    /// Self-update state (Sparkle checks, prompts and installs).
    let updates = UpdateController()

    /// Tracks the main window's visibility so the activation policy can be
    /// re-evaluated when it opens and closes.
    var isMainWindowVisible = false {
        didSet { fleet.setMainWindowVisible(isMainWindowVisible) }
    }
    /// The last state `renderFleetState` drew (and into which menu), so an
    /// unchanged poll renders nothing.
    var lastRenderedMenuState: MenuViewState?
    var lastRenderedMenuIdentity: ObjectIdentifier?
    /// A quit is waiting for the engine to stop (a second quit just waits too).
    private var isShuttingDown = false

    var setupIncomplete: Bool {
        get { fleet.setupIncomplete }
        set {
            fleet.setupIncomplete = newValue
            applySetupItemVisibility(to: menu)
        }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        Paths.ensureSupportDirectories()
        Log.setLogFile(directory: Paths.logsDirectory)
        installMainMenu()
        let mode = AppPreferences.launchMode
        if mode.showsStatusItem {
            installStatusItem()
        }
        FleetIntentEnvironment.bridge = AppFleetIntentBridge(controller: fleet)
        // Off the launch path: the Keychain read can block on an access prompt
        // or a locked keychain, and the menu and window must stay usable. The
        // window opens below; if setup turns out to be incomplete the
        // bootstrap brings the Setup tab up itself.
        Task {
            await bootstrapEngine()
            autoStartFleetIfEnabled()
        }
        fleet.startPolling()
        // Check whether a LaunchAgent plist exists but points at a binary
        // that no longer exists (app removed without `kinhin daemon uninstall`).
        Task { @MainActor in fleet.detectStaleDaemonPlist() }
        // Sparkle's background checks (once a day, per SUScheduledCheckInterval).
        updates.startScheduledChecks()
        // An upgrade leaves the previous build's daemon running in memory; restart it onto this build.
        Task { @MainActor in
            do {
                try await Daemon.restartIfStale()
            } catch {
                Log.warn("app", "could not restart the daemon for this build: \(error.localizedDescription)")
            }
        }
        observeControllers()
        // Launch-mode surface selection: the main window opens unless the user
        // chose menu-bar-only or onboarding already took the stage (the
        // window's Setup tab is the launch surface until setup completes).
        if mode.showMainWindowAtLaunch {
            openMainWindow()
        }
        applyActivationPolicy()
    }

    /// Quitting with an in-process engine waits for it to stop (tearing its
    /// VMs down) before the process exits; a daemon owns its own fleet, so
    /// there is nothing to wait for.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard fleet.engine != nil else {
            fleet.stopPolling()
            return .terminateNow
        }
        guard !isShuttingDown else { return .terminateLater }
        isShuttingDown = true
        Task {
            await fleet.shutdown()
            NSApp.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    // MARK: - Activation policy (normal app vs menu bar app)

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

    // MARK: - Engine wiring

    func bootstrapEngine(reopenSetupOnFailure: Bool = true) async {
        #if DEBUG
            // Screen-recording demo: a scripted fleet, no config, Keychain, daemon or forge touched.
            if let demo = DemoFleetServing.fromEnvironment() {
                fleet.service = demo
                setupIncomplete = false
                Log.info("app", "demo mode (KINHIN_DEMO): replaying a scripted fleet")
                return
            }
        #endif
        // First-run convenience: materialize the starter config (never
        // overwriting). The checklist still asks for a real repo, so this
        // can't mask an unfinished setup.
        // The probes below read files and ping a socket: off the main actor.
        let created = await Task.detached { ConfigLoader.createIfMissing() }.value
        if created {
            Log.info("app", "first run: wrote starter config at \(Paths.config.path)")
        }
        // Attach to daemon when one is running; otherwise run the engine in-process.
        let daemonBackend = await FleetBackend.attachToDaemon()
        // A broken config stays a broken config for the wizard to surface;
        // loading it here is only a fast-path gate for "skip onboarding".
        // Through ConfigStore, so a parse error is said (under the status
        // line) instead of looking like "nothing configured yet".
        let loaded: Result<KinhinConfig?, any Error> =
            daemonBackend != nil
            ? .success(nil)
            : await Task.detached { Self.loadLaunchConfig() }.value
        var loadedConfig: KinhinConfig?
        var configProblem: String?
        switch loaded {
        case .success(let cfg):
            loadedConfig = cfg
        case .failure(let error):
            Log.warn("app", "config.yaml can't be read at launch: \(error.localizedDescription)")
            configProblem = StatusLine.unreadableConfig(error).text
        }
        if let daemonBackend {
            fleet.backend = daemonBackend
            setupIncomplete = false
            fleet.setProblem(.launch, nil)
            Log.info("app", "attaching to running daemon")
        } else if let cfg = loadedConfig,
            // A template config (placeholder repo, no gitea:) is not a
            // working config — keep onboarding up instead of booting a
            // fleet against "your-org/your-repo".
            ConfigLoader.hasAnyForge(cfg),
            // GitHub PAT, or (Gitea-only config) the Gitea token.
            let pat = await engineTokenLoggingFailure(for: cfg),
            // tart, or a Linux runtime (Docker / Apple container) to run on.
            cfg.canRunOnThisHost()
        {
            installInProcessEngine(config: cfg, token: pat)
        } else {
            setupIncomplete = true
            fleet.setProblem(.launch, configProblem)
            Log.info("app", "setup incomplete — the guided setup opens")
            if reopenSetupOnFailure { openMainWindow() }
        }
    }

    /// config.yaml for the launch gate, read through `ConfigStore`: nil when
    /// there is none yet (or it is blank), a failure when it exists but can't
    /// be read or parsed.
    nonisolated static func loadLaunchConfig(at url: URL = Paths.config) -> Result<KinhinConfig?, any Error> {
        Result {
            let yaml = try ConfigStore.text(at: url)
            guard !yaml.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
            return try ConfigLoader.parse(yaml)
        }
    }

    /// Builds the in-process engine for a complete config. The config and
    /// token are there, so the guided setup has nothing left to ask: a build
    /// failure (e.g. tart or softnet missing) is shown under the status line
    /// instead of reopening setup, which would only show a finished checklist.
    func installInProcessEngine(config cfg: KinhinConfig, token pat: String) {
        do {
            fleet.backend = .inProcess(try fleet.environment.makeEngine(cfg, pat))
            setupIncomplete = false
            fleet.setProblem(.launch, nil)
            Log.info("app", "no daemon; running engine in-process (not started yet)")
        } catch is CancellationError {
            Log.info("app", "engine build cancelled")
        } catch {
            Log.error("app", "could not build engine: \(error.localizedDescription)")
            fleet.setProblem(
                .launch,
                String(
                    localized:
                        "The fleet engine couldn't be created: \(error.localizedDescription). The fleet can't run until this is fixed and kinhin is reopened.",
                    bundle: .l10n, comment: "Status line when the app can't build its fleet engine; %@ is the reason"))
        }
    }

    /// The engine token for launch. A Keychain failure is logged and yields nil,
    /// which routes to the guided setup; its checklist then shows the
    /// "Keychain error" row instead of asking for a token that is already saved.
    private func engineTokenLoggingFailure(for cfg: KinhinConfig) async -> String? {
        do {
            // Detached: SecItemCopyMatching blocks until the user answers a
            // Keychain prompt, and must never hold the main thread.
            return try await Task.detached { try ConfigLoader.engineToken(for: cfg) }.value
        } catch {
            Log.error("app", "could not read the forge token at launch: \(error.localizedDescription)")
            return nil
        }
    }

    /// Starts the in-process fleet at launch when the user asked for it. A
    /// running daemon owns its own lifecycle, and an incomplete setup has no
    /// engine, so neither is touched.
    func autoStartFleetIfEnabled(enabled: Bool = AppPreferences.autoStartFleet) {
        guard enabled, fleet.engine != nil else { return }
        Log.info("app", "auto-starting the fleet (Settings → App)")
        Task { await runAutoStart() }
    }

    /// Starts the fleet through `perform`, so the status item shows
    /// "Starting…". Nobody pressed anything, so a failure isn't a modal at
    /// launch: it stays under the status line until a start works.
    func runAutoStart() async {
        do {
            try await fleet.perform(.start)
        } catch is CancellationError {
            return
        } catch {
            Log.error("app", "auto-start failed: \(error.localizedDescription)")
            fleet.setProblem(
                .launch,
                String(
                    localized:
                        "The fleet didn't start at launch: \(error.localizedDescription). Start it from the menu or the Fleet tab.",
                    bundle: .l10n, comment: "Status line when auto-start at launch fails; %@ is the reason"))
        }
    }

    // MARK: - Rendering

    /// Re-renders the menu-bar surfaces whenever the controllers change.
    /// AppKit menus aren't observable, so this is the one render path: it
    /// reads the controller state inside `withObservationTracking` and
    /// re-arms itself after every change.
    func observeControllers() {
        withObservationTracking {
            renderControllerState()
        } onChange: { [weak self] in
            // onChange fires before the mutation lands; hop so the re-read
            // sees the new value.
            Task { @MainActor [weak self] in self?.observeControllers() }
        }
    }

    /// Reads every observed property up front (before any early return), so
    /// the tracking never goes empty while the status item is absent.
    func renderControllerState() {
        _ = fleet.status
        _ = fleet.pendingFleetAction
        _ = fleet.unreachableReason
        _ = fleet.problems
        _ = updates.pendingVersion
        _ = updates.updateCardState
        renderFleetState()
        refreshUpdateItems()
    }
}
