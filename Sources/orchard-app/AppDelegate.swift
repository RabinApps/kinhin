import AppKit
import OrchardKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    var statusItem: NSStatusItem?
    var menu: NSMenu?
    // Hold the controller, not just its window: NSControl.target is unretained,
    // so the controller must stay alive for the setup buttons to work.
    var setupController: SetupWindowController?
    var runtimesController: RuntimesWindowController?
    var tokenSettingsController: TokenSettingsWindowController?

    // Engine is either owned here (in-process mode) or reached via RPC.
    var engine: FleetEngine?
    var client: RPCClient?
    private var pollTimer: Timer?
    private var updateTimer: Timer?

    // Update check state
    var lastUpdateCheck: Date?
    var pendingUpdate: UpdateInfo?
    var updateDownloadTask: Task<Void, Never>?
    var updateCheckTask: Task<Void, Never>?
    var updateChecker: UpdateChecker {
        UpdateChecker(repo: UpdatePreferences.repo)
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        Paths.ensureSupportDirectories()
        Log.setLogFile(directory: Paths.logsDirectory)
        // A crash in the setup path must never be silent: surface the reason
        // in a visible window before anything can go wrong.
        NSSetUncaughtExceptionHandler { exception in
            orchardPresentCrashAlert(reason: exception.reason ?? exception.name.rawValue)
        }
        installStatusItem()
        bootstrapEngine()
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
    }

    func applicationWillTerminate(_ notification: Notification) {
        Task { await engine?.stop() }
        updateCheckTask?.cancel()
        updateDownloadTask?.cancel()
    }

    // MARK: Engine wiring

    func bootstrapEngine() {
        // First-run convenience: materialize the starter config (never
        // overwriting). The checklist still asks for a real repo, so this
        // can't mask an unfinished setup.
        if ConfigLoader.createIfMissing() {
            Log.info("app", "first run: wrote starter config at \(Paths.config.path)")
        }
        // Attach to daemon when one is running; otherwise run the engine in-process.
        if RPCClient.isDaemonAlive() {
            client = RPCClient()
            Log.info("app", "attaching to running daemon")
        } else if FileManager.default.fileExists(atPath: Paths.config.path),
                  let cfg = try? ConfigLoader.load(),
                  // A template config (placeholder repo) is not a working
                  // config — keep onboarding up instead of booting a fleet
                  // against "your-org/your-repo".
                  !ConfigLoader.isTemplate(cfg),
                  let pat = KeychainTokenStore.load(),
                  TartController.isInstalled(configuredPath: cfg.tartPath) {
            do {
                let tart = try TartController(configuredPath: cfg.tartPath)
                // Factory-based init so a later "Token Settings…" swap
                // the client without an app restart.
                engine = FleetEngine(
                    config: cfg,
                    pat: pat,
                    tart: tart,
                    store: FleetStore(),
                    ssh: SSHExecutor(),
                    host: ResourceProbe().snapshot()
                )
                Log.info("app", "no daemon; running engine in-process (not started yet)")
            } catch {
                Log.error("app", "could not build engine: \(error.localizedDescription)")
            }
        } else {
            Log.info("app", "setup incomplete — opening setup")
            // Always open onboarding when setup is incomplete: a bare status-bar
            // icon would look like the app did nothing (the "silent crash").
            openSetup()
        }
    }



    // MARK: Refresh

    func refresh() async {
        var status: FleetStatus?
        if let engine {
            status = await engine.status()
        } else if let client {
            if let response = try? client.send(method: .status),
               response.ok, let payload = response.payload {
                status = try? JSONDecoder().decode(FleetStatus.self, from: payload)
            }
        }
        await MainActor.run { self.apply(status: status) }
    }


}
