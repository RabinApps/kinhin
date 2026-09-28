import Foundation

// MARK: - Control (start/stop, cache sweep, pause, status)

extension FleetEngine {
    public func start() async {
        let alreadyRunning = runState.withLock { state -> Bool in
            let was = state.running
            state.running = true
            return was
        }
        guard !alreadyRunning else { return }
        guard await prepareStart() else { return }
        await launch()
    }

    /// Set the run flag without starting anything — the daemon's rebuild
    /// calls this before `prepareStart()`, mirroring what `start()` does.
    func markRunning() {
        runState.withLock { $0.running = true }
    }

    /// First half of `start()`: verify and attach every configured forge.
    /// Returns false (engine left stopped, reason in lastError) when no forge
    /// is usable. Spawns nothing and touches no instance, so the daemon's
    /// config rebuild can run it while the previous engine still owns the
    /// fleet. Callers must have set `running = true` first.
    func prepareStart() async -> Bool {
        if let platform = config.docker?.platform, platform.isEmulated {
            Log.warn("engine", LinuxPlatform.emulationNotice)
        }

        // Verify the PAT can manage runners for the scope BEFORE spawning
        // anything — a forbidden org token otherwise surfaces as per-VM
        // registration failures (and deleted VMs) instead of a clear answer.
        // Failure keeps the engine stopped and surfaced via lastError.
        // Each configured forge is verified independently: one failing forge
        // (bad token, missing org rights) must not take the other down. The
        // failing forge is detached with its reason in lastError; the fleet
        // only refuses to start when NO forge is usable.
        var githubProblem: String?
        if config.githubEnabled {
            let verification = await OrgPermissionProbe.verify(github: github, scope: config.repo)
            if !verification.ok {
                githubProblem = verification.message
                forgeState.withLock { $0.retry.markGitHubDetached(now: Date()) }
                _ = forgeState.withLock { $0.byPlatform.removeValue(forKey: "github") }
                Log.error("engine", "GitHub unavailable: \(verification.message)")
            }
        }
        await attachGiteaForgeIfNeeded()
        await attachForgejoForgeIfNeeded()
        await attachAccountsIfNeeded()
        let attachedCount = forgeState.withLock { $0.byPlatform.count }
        guard attachedCount > 0 else {
            let giteaProblem = await statusBox.get().lastError
            let message =
                githubProblem
                ?? giteaProblem
                ?? "no forge configured — set a GitHub repo, a gitea: section, or an accounts: list"
            Log.error("engine", "startup blocked: \(message)")
            await statusBox.modify {
                $0.running = false
                $0.lastError = message
            }
            runState.withLock { $0.running = false }
            return false
        }
        if let githubProblem {
            // Running on the remaining forge(s): keep the reason visible.
            await statusBox.modify { $0.lastError = "GitHub: \(githubProblem)" }
        }
        return true
    }

    /// Second half of `start()`: adopt surviving instances and begin
    /// reconciling. Run only after `prepareStart()` succeeded — and, on a
    /// config rebuild, only after the previous engine detached, so no
    /// instance is ever driven by two engines at once.
    func launch() async {
        let served = forgeState.withLock { $0.byPlatform.keys.sorted().joined(separator: " + ") }
        Log.info("engine", "starting fleet engine for \(served) (capacity cap: \(capacity.maxConcurrent))")
        await recoverIfNeeded()
        startCachePruneSweepIfNeeded()
        // Mirror the flag into the status snapshot before returning (as
        // `stop()` does): the first reconcile pass that would sync it runs in
        // the task below, so callers reading status() right after start()
        // (e.g. the daemon's config reload) could otherwise see running=false.
        let isRunning = running
        await statusBox.modify { $0.running = isRunning }
        let task = Task { [weak self] () -> Void in
            guard let self else { return }
            await self.reconcileLoop()
        }
        reconcileTask = task
    }

    public func stop() async {
        runState.withLock { $0.running = false }
        Log.info("engine", "stopping fleet engine")
        reconcileTask?.cancel()
        reconcileTask = nil
        cachePruneTask?.cancel()
        cachePruneTask = nil
        // Mirror the flag into the status snapshot now: the reconcile pass
        // that would sync it is being cancelled, so status().running would
        // otherwise stay stale true until the engine is started again.
        await statusBox.modify { $0.running = false }
        // A token replaced while stopped must not survive into the next run
        // via the cache (minted under the old PAT's authority).
        invalidateRegistrationTokens()
        await pauseAllVMs()
    }

    // MARK: - Cache maintenance

    /// Daily host-cache sweep while the fleet runs. Failures log and are
    /// ignored — pruning must never disturb scaling. The pruner's grace
    /// window keeps it from racing any in-flight download or install.
    func startCachePruneSweepIfNeeded() {
        guard ToolchainCachePolicy(from: config.toolchains).autoPrune else { return }
        cachePruneTask = Task { [weak self] () -> Void in
            while !Task.isCancelled {
                do {
                    try await Task.sleep(for: .seconds(86_400))
                } catch is CancellationError {
                    return  // engine stopped: the sweep task ends
                } catch {
                    Log.warn("engine", "cache sweep sleep failed: \(error.localizedDescription)")
                    return
                }
                guard let self else { return }
                let policy = ToolchainCachePolicy(from: self.config.toolchains)
                guard policy.autoPrune else { continue }
                ToolchainCachePruner().prune(policy: policy)
            }
        }
    }

    // MARK: - Pause and status

    public func setPaused(_ value: Bool) async {
        runState.withLock { $0.paused = value }
        Log.info("engine", value ? "paused (no new VMs will be started)" : "resumed")
        await statusBox.modify { $0.paused = value }
    }

    public func status() async -> FleetStatus {
        var status = await statusBox.get()
        // Records live in the store; derive them on read so snapshots can
        // never go stale relative to store mutations.
        status.records = store.all
        status.runtime = runtime.id.rawValue
        // The UI surfaces this while paused so a deliberate pause doesn't
        // read as stuck — including when the queue gets re-checked.
        status.autoResume = config.autoResume
        status.pollInterval = config.pollInterval
        let runtimeCaps = capsByRuntime
        if !runtimeCaps.isEmpty {
            var caps: [String: String] = [:]
            for (id, cap) in runtimeCaps {
                caps[id.rawValue] = String(cap)
            }
            status.capacityByRuntime = caps
        }
        return status
    }

    /// Manually delete one VM (from the UI). Reconcile will scale back up if
    /// demand still exists; the user should pause first to hold the fleet down.
    public func deleteVM(id: String) async {
        Log.info("engine", "manual delete of \(id)")
        await runTelemetryIfPossible(id)
        await deleteVMRecord(id: id, reason: "manual delete")
    }
}
