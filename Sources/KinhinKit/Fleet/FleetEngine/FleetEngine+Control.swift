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
        // A stop() that landed while the forges were being verified wins:
        // launching now would resurrect a fleet the caller just stopped.
        guard running else { return }
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
        // One-line reproducibility nudge: base_image is set but not pinned,
        // so the next prepare may bake different bits than the last one.
        // The default (no key) is never nagged about.
        if let drift = TartBaseImage.mutableTagWarning(for: config.baseImage) {
            Log.warn("engine", "base image \(drift)")
        }

        // Verify each forge can manage its runners BEFORE spawning anything
        // — a forbidden token otherwise surfaces as per-VM registration
        // failures (and deleted VMs) instead of a clear answer. The primary
        // GitHub account's construction-time forge is an unverified
        // placeholder: detach it so the verified account attach below is the
        // real gate. A failing account is detached with its reason in
        // lastError; the fleet only refuses to start when NO forge is usable.
        if let primary = config.primaryGitHub {
            _ = forgeState.withLock { $0.byPlatform.removeValue(forKey: primary.name) }
        }
        await attachAccountsIfNeeded()
        if !detachedAccounts().isEmpty {
            // Failed accounts retry on the backoff schedule (30s, doubling),
            // not on the next reconcile pass.
            forgeState.withLock {
                $0.retry.scheduleNext(after: ForgeRetryState.initialDelay, now: Date())
            }
        }
        let attachedCount = forgeState.withLock { $0.byPlatform.count }
        guard attachedCount > 0 else {
            let problem = await statusBox.get().lastError
            let message = problem ?? "no forge configured — declare at least one accounts: entry"
            Log.error("engine", "startup blocked: \(message)")
            await statusBox.modify { $0.setAlert("startup", message) }
            runState.withLock { $0.running = false }
            return false
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
        // The store was read at construction. On a hand-over the previous engine kept writing until it
        // detached, so what is on disk now is newer: adopt that, not the stale copy (which would lose the
        // platform and image of every record created in between).
        store.reload()
        await recoverIfNeeded()
        await startAttachedListeners()
        startCachePruneSweepIfNeeded()
        let task = Task { [weak self] () -> Void in
            guard let self else { return }
            await self.reconcileLoop()
        }
        reconcileTask = task
        await startHealing()
    }

    public func stop() async {
        runState.withLock { $0.running = false }
        Log.info("engine", "stopping fleet engine")
        healing.stopLoop()
        reconcileTask?.cancel()
        reconcileTask = nil
        cachePruneTask?.cancel()
        cachePruneTask = nil
        // A token replaced while stopped must not survive into the next run
        // via the cache (minted under the old PAT's authority).
        invalidateRegistrationTokens()
        await stopAttachedListeners()
        await deleteAllActiveVMs()
    }

    // MARK: - Cache maintenance

    /// How often the host cache and the derived images are swept.
    static let cacheSweepInterval: TimeInterval = 86_400

    /// Daily host-cache sweep while the fleet runs. The first one runs at
    /// launch when the sweep marker says one is due, so an app that restarts
    /// (or an engine rebuilt by every config change) more often than daily
    /// still sweeps. Failures log and are ignored — pruning must never
    /// disturb scaling. The pruner's grace window keeps it from racing any
    /// in-flight download or install.
    func startCachePruneSweepIfNeeded() {
        guard ToolchainCachePolicy(from: config.toolchainCache).autoPrune || !config.projects.isEmpty else { return }
        cachePruneTask = Task { [weak self] () -> Void in
            while !Task.isCancelled {
                guard let self else { return }
                await self.runCacheSweep()
                do {
                    try await Task.sleep(for: .seconds(Self.cacheSweepInterval))
                } catch is CancellationError {
                    return  // engine stopped: the sweep task ends
                } catch {
                    Log.warn("engine", "cache sweep sleep failed: \(error.localizedDescription)")
                    return
                }
            }
        }
    }

    /// One sweep, skipped when the marker says the last one was recent. The
    /// tree walk is synchronous file I/O, so it runs detached at utility
    /// priority instead of holding a cooperative-pool thread.
    func runCacheSweep(pruner: ToolchainCachePruner = ToolchainCachePruner()) async {
        guard pruner.isSweepDue(minInterval: Self.cacheSweepInterval) else { return }
        await pruneProjectImages()
        let policy = ToolchainCachePolicy(from: config.toolchainCache)
        guard policy.autoPrune else { return }
        let root = pruner.cacheRoot
        await Task.detached(priority: .utility) {
            ToolchainCachePruner(cacheRoot: root).prune(policy: policy, minInterval: Self.cacheSweepInterval)
        }.value
    }

    // MARK: - Pause and status

    public func setPaused(_ value: Bool) async {
        runState.withLock { $0.paused = value }
        // A resume acts on the queue right away, not after an idle backoff.
        if !value { pollSoon() }
        Log.info("engine", value ? "paused (no new VMs will be started)" : "resumed")
    }

    /// `includeUsage: false` skips the CPU/RAM sampling (a caller that shows
    /// neither, such as the menu bar render, does not pay for it).
    public func status(includeUsage: Bool = true) async -> FleetStatus {
        var status = await statusBox.get()
        // Records live in the store and the run flags in `runState`; derive
        // them on read so a snapshot can never disagree with either.
        status.records = store.all
        if includeUsage {
            let usage = await usageSampler.snapshot(for: status.records)
            status.host = usage.host
            for index in status.records.indices {
                status.records[index].usage = usage.byInstance[status.records[index].id]
            }
        }
        let state = runState.withLock { $0 }
        status.running = state.running
        status.paused = state.paused
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
    ///
    /// Throws `EngineError.unknownVM` for an id that is malformed or not in
    /// the store: the delete also removes same-named forge runners and stops
    /// the VM by name, so it must never run on an arbitrary string.
    public func deleteVM(id: String) async throws {
        guard VMRecord.isValidID(id), store.all.contains(where: { $0.id == id }) else {
            throw EngineError.unknownVM(id)
        }
        Log.info("engine", "manual delete of \(id)")
        await deleteVMRecord(id: id, reason: "manual delete")
    }

    /// Requeue the queued jobs of one forge: drop the pending work and ask
    /// the forge for a fresh set, so reconcile re-spawns the jobs. `forge` is
    /// the account name of the target; org-scoped forges fall back to every
    /// repo the token can see.
    public func requeueQueuedJobs(for forge: ForgeID) async throws {
        guard let target = forges[forge.rawValue] as? any ForgeWithQueuedJobs else {
            throw EngineError.forgeNotFound(forge)
        }
        try await target.userRequeueQueuedJobs()
    }

    /// Mark the queued jobs of one forge as skipped: the reconcile pass
    /// drops the matching jobs from the re-synced set, so the queue drains.
    public func skipQueuedJobs(for forge: ForgeID) async throws {
        guard let target = forges[forge.rawValue] as? any ForgeWithQueuedJobs else {
            throw EngineError.forgeNotFound(forge)
        }
        try await target.userSkipQueuedJobs()
    }
}
