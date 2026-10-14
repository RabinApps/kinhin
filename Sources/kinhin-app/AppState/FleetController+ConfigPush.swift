import Foundation
import KinhinKit

// Pushing config edits to a running engine (live reload or rebuild).

@MainActor
extension FleetController {
    /// Config writes (Runtimes pane, Config tab) reach whoever owns the
    /// engine so the running fleet picks up the change. Routing-only edits
    /// (including `images:` entries and `projects:` rules) apply live; anything
    /// else (scope, bounds, VM shape, forge sections) restarts the engine
    /// automatically — the old behavior was to silently keep the stale config
    /// until a manual daemon restart.
    /// Edits are debounced by `configPush`: a save burst (e.g. a stepper drag) flushes once.
    /// A push that fails to apply is always shown under the status line;
    /// `alertOnFailure` (a save the user just made in the window) also puts up
    /// an alert, since the form they saved from has already said "saved".
    func pushConfigToEngine(alertOnFailure: Bool = true) {
        if alertOnFailure { configPushAlertsOnFailure = true }
        configPush.push()
    }

    /// Toggles `auto_resume:` in config.yaml and pushes the change to whoever
    /// owns the engine — the App Intent's entry point, matching what the
    /// Capacity tab's Apply does for the same field. Throws when the config
    /// file is missing or the edited result fails validation (nothing is
    /// written in that case).
    func setAutoResumePolicy(_ on: Bool) async throws {
        try GeneralConfigEditor.apply(.autoResume(on), to: environment.configURL)
        // From Shortcuts, with nobody at the window: no modal, the status line says it.
        pushConfigToEngine(alertOnFailure: false)
    }

    /// One flush of the config push: reload into the engine or daemon, then
    /// say what happened. A failure keeps the fleet on its previous config,
    /// and the user is told so instead of it only reaching the log.
    func applyConfigToEngine() async {
        let alert = configPushAlertsOnFailure
        configPushAlertsOnFailure = false
        var failure: ConfigNotAppliedError?
        do {
            try await reloadConfigIntoBackend()
            setProblem(.configPush, nil)
        } catch is CancellationError {
            // Not a failure: whoever cancelled will push again.
        } catch {
            let notApplied = ConfigNotAppliedError(reason: error.localizedDescription)
            setProblem(.configPush, notApplied.localizedDescription)
            if alert { failure = notApplied } else { Log.warn("app", notApplied.localizedDescription) }
        }
        await refresh()
        if let failure {
            AlertKit.present(
                error: failure,
                title: String(
                    localized: "Config change not applied", bundle: .l10n,
                    comment: "Alert title when a saved config edit couldn't be applied to the running fleet"))
        }
    }

    /// Hands the on-disk config to whoever owns the engine. Throws when it
    /// could not be applied; the fleet then keeps its current config.
    private func reloadConfigIntoBackend() async throws {
        if let engine {
            // Off the main actor: loading reads and parses the file.
            let url = environment.configURL
            let cfg = try await Task.detached { try ConfigLoader.load(from: url) }.value
            if FleetEngine.restartRequired(from: engine.activeConfig, to: cfg) {
                try await rebuildInProcessEngine(from: engine, config: cfg)
            } else {
                let snapshot = environment.hostSnapshot
                let host = await Task.detached { snapshot() }.value  // a statfs/sysctl probe
                engine.applyReloaded(config: cfg, host: host)
                Log.info("app", "routing reloaded into in-process engine")
            }
        }
        if case .daemon(let client)? = backend {
            try await client.perform { try $0.reloadConfig() }
            Log.info("app", "daemon notified: config reloaded (restarted if the change required it)")
        }
    }

    /// Rebuild the in-process engine from a new config. Deliberately not
    /// stop()→start(): stop tears every active VM down. The old engine is
    /// detached (scaling stops, lifecycle tasks cancel) while its instances
    /// keep running; the replacement adopts them via the standard recovery
    /// path, then resumes serving at the previous running/paused state.
    /// Throws (old engine and config kept) when the replacement can't be
    /// built or doesn't start.
    private func rebuildInProcessEngine(from old: FleetEngine, config cfg: KinhinConfig) async throws {
        let enginePAT: String?
        do {
            // Detached: the Keychain read can block on an access prompt.
            let loadToken = environment.engineToken
            enginePAT = try await Task.detached { try loadToken(cfg) }.value
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw ConfigPushFailure.keychain(error.localizedDescription)
        }
        guard let pat = enginePAT else { throw ConfigPushFailure.tokenMissing }
        let replacement = try environment.makeEngine(cfg, pat)
        switch await old.handOver(to: replacement) {
        case .rejected(let error):
            // Startup verification failed (bad PAT, transient network):
            // keep the old engine instead of trading a running fleet for
            // a dead one.
            throw ConfigPushFailure.replacementDidNotStart(error)
        case .handedOver(let wasRunning, let wasPaused):
            service = FleetBackend.inProcess(replacement)
            Log.info(
                "app",
                "config change required a restart — engine rebuilt (running: \(wasRunning), paused: \(wasPaused))")
        }
    }
}

/// A saved config edit the running fleet didn't take: says why, and that the
/// previous config is still in effect.
struct ConfigNotAppliedError: LocalizedError {
    let reason: String

    var errorDescription: String? {
        String(
            localized:
                "Your config change was saved but couldn't be applied: \(reason). The fleet is still using the previous config.",
            bundle: .l10n, comment: "Alert and status line when a config edit can't reach the fleet; %@ is the reason")
    }
}

/// Why a config edit that needs an engine restart couldn't restart it.
enum ConfigPushFailure: LocalizedError {
    case keychain(String)
    case tokenMissing
    case replacementDidNotStart(String)

    var errorDescription: String? {
        switch self {
        case .keychain(let reason):
            return String(
                localized: "the forge token couldn't be read from the Keychain (\(reason))", bundle: .l10n,
                comment: "Reason a config edit wasn't applied; %@ is the Keychain error")
        case .tokenMissing:
            return String(
                localized: "the forge token is missing from the Keychain", bundle: .l10n,
                comment: "Reason a config edit wasn't applied")
        case .replacementDidNotStart(let reason):
            return String(
                localized: "the fleet engine didn't restart with it (\(reason))", bundle: .l10n,
                comment: "Reason a config edit wasn't applied; %@ is the engine's startup error")
        }
    }
}
