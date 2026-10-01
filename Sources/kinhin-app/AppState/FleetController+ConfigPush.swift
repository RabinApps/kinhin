import Foundation
import KinhinKit

// Pushing config edits to a running engine (live reload or rebuild).

@MainActor
extension FleetController {
    /// Config writes (Runtimes pane, Config tab) reach whoever owns the
    /// engine so the running fleet picks up the change. Routing-only edits
    /// apply live; anything else (scope, bounds, VM shape, images, forge
    /// sections) restarts the engine automatically — the old behavior was
    /// to silently keep the stale config until a manual daemon restart.
    /// Edits are debounced: a save burst (e.g. a stepper drag) flushes once.
    func pushConfigToEngine() {
        pendingConfigEdits = true
        guard !isConfigPushScheduled else { return }
        isConfigPushScheduled = true
        Task { [weak self, delay = configPushDelay] in
            do {
                try await Task.sleep(for: delay)  // debounce a save burst
            } catch {
                self?.isConfigPushScheduled = false  // cancelled: nothing to push
                return
            }
            guard let self else { return }
            while self.pendingConfigEdits {
                self.pendingConfigEdits = false
                await self.applyConfigToEngine()
            }
            self.isConfigPushScheduled = false
        }
    }

    /// Toggles `auto_resume:` in config.yaml and pushes the change to whoever
    /// owns the engine — the App Intent's entry point, matching what the
    /// Capacity tab's Apply does for the same field. Throws when the config
    /// file is missing or the edited result fails validation (nothing is
    /// written in that case).
    func setAutoResumePolicy(_ on: Bool) async throws {
        try GeneralConfigEditor.apply(.autoResume(on), to: Paths.config)
        pushConfigToEngine()
    }

    private func applyConfigToEngine() async {
        if let configFlushOverride {
            await configFlushOverride()
            return
        }
        if let engine {
            let cfg: KinhinConfig
            do {
                cfg = try ConfigLoader.load()
            } catch {
                Log.warn(
                    "app",
                    "config reload skipped — \(error.localizedDescription); the running fleet keeps its current config"
                )
                return
            }
            if FleetEngine.restartRequired(from: engine.activeConfig, to: cfg) {
                await rebuildInProcessEngine(from: engine, config: cfg)
            } else {
                engine.applyReloaded(config: cfg, host: ResourceProbe().snapshot())
                Log.info("app", "routing reloaded into in-process engine")
            }
        } else if case .daemon(let client)? = backend {
            do {
                try await client.perform { try $0.reloadConfig() }
                Log.info("app", "daemon notified: config reloaded (restarted if the change required it)")
            } catch {
                Log.warn("app", "daemon reload failed: \(error.localizedDescription)")
            }
        }
        await refresh()
    }

    /// Rebuild the in-process engine from a new config. Deliberately not
    /// stop()→start(): stop tears every active VM down. The old engine is
    /// detached (scaling stops, lifecycle tasks cancel) while its instances
    /// keep running; the replacement adopts them via the standard recovery
    /// path, then resumes serving at the previous running/paused state.
    private func rebuildInProcessEngine(from old: FleetEngine, config cfg: KinhinConfig) async {
        let enginePAT: String?
        do {
            enginePAT = try ConfigLoader.engineToken(for: cfg)
        } catch {
            Log.error(
                "app",
                "config change needs an engine restart but the Keychain failed (\(error.localizedDescription)) — the fleet keeps running on the old config"
            )
            return
        }
        guard let pat = enginePAT else {
            Log.warn(
                "app",
                "config change needs an engine restart but the required forge token is missing — the fleet keeps running on the old config"
            )
            return
        }
        do {
            let replacement = try FleetEngine.production(config: cfg, token: pat)
            let previous = await old.status()
            let wasRunning = previous.running
            let wasPaused = previous.paused
            // A stopped fleet stays stopped across a rebuild — a config edit
            // must never start spawning VMs.
            if wasRunning {
                await replacement.start()
                if wasPaused { await replacement.setPaused(true) }
            }
            let status = await replacement.status()
            if wasRunning, !status.running, let error = status.lastError {
                // Startup verification failed (bad PAT, transient network):
                // keep the old engine instead of trading a running fleet for
                // a dead one.
                Log.error("app", "rebuild did not start: \(error) — keeping the previous engine and config")
                return
            }
            await old.detachKeepingInstances()
            service = FleetBackend.inProcess(replacement)
            Log.info(
                "app",
                "config change required a restart — engine rebuilt (running: \(wasRunning), paused: \(wasPaused))")
        } catch {
            Log.error(
                "app",
                "engine rebuild failed: \(error.localizedDescription) — the fleet keeps running on the old config")
        }
    }
}
