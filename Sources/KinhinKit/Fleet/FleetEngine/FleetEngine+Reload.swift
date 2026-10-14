import Foundation
import Synchronization

// FleetEngine — live config reload: what a running engine can adopt in
// place (routing, caps, labels, projects) and the hand-off when it must be rebuilt.
extension FleetEngine {
    /// Which parts of a config edit the *running* engine can adopt without
    /// a rebuild: the routing model (pools/routes/budget), the capacity
    /// partition, the GitHub forge's label set, the named `images:` entries
    /// and the `projects:` rules — exactly what `applyReloaded` swaps under
    /// the locks. Everything else (bounds, poll cadence, per-VM shape,
    /// reserve, forge sections, toolchains) lives in the frozen `config` the
    /// engine was built with, so a change there silently does nothing until
    /// the engine is rebuilt.
    public static func restartRequired(from old: KinhinConfig, to new: KinhinConfig) -> Bool {
        var a = old
        var b = new
        a.runtimes = nil
        b.runtimes = nil
        a.projects = []
        b.projects = []
        a.images = []
        b.images = []
        a.labels = []
        b.labels = []
        return a != b
    }

    /// The frozen config this engine instance was built with — read live
    /// (e.g. to diff against the on-disk file before deciding between a
    /// hot reload and a rebuild).
    public var activeConfig: KinhinConfig { config }

    /// Stop scaling and cancel lifecycle work while keeping every spawned
    /// instance and its record: the replacement engine's recovery adopts
    /// them (rebooted engine: phases move back to booting where needed).
    /// Deliberately NOT `stop()` — that tears all instances down, which a
    /// config rebuild must never do.
    public func detachKeepingInstances() async {
        runState.withLock { $0.running = false }
        healing.stopLoop()
        cachePruneTask?.cancel()
        cachePruneTask = nil
        // Wait out an in-flight reconcile pass first: one already in its
        // spawn loop could otherwise start a lifecycle after the drain below
        // and keep driving an instance the replacement engine adopts.
        let reconcile = reconcileTask
        reconcileTask = nil
        if let reconcile {
            reconcile.cancel()
            await drain([reconcile], timeout: lifecycleDrainTimeout)
        }
        let tasks = lifecycleTasks.withLock { tasks -> [Task<Void, Never>] in
            defer { tasks.removeAll() }
            return Array(tasks.values)
        }
        for task in tasks { task.cancel() }
        await drain(tasks, timeout: lifecycleDrainTimeout)
        // Background work the pass started: a forge attach is cancelled, but a teardown is let finish
        // (cancelling one mid-way would drop its record) so the replacement never races it.
        let retry = forgeState.withLock { state in
            defer { state.retry.inFlight = nil }
            return state.retry.inFlight
        }
        retry?.cancel()
        await drain([retry].compactMap { $0 }, timeout: lifecycleDrainTimeout)
        await settleDeletes(timeout: lifecycleDrainTimeout)
        invalidateRegistrationTokens()
    }

    /// What `handOver(to:)` did.
    public enum HandOverResult: Sendable, Equatable {
        /// The replacement now owns the fleet; the old engine is detached.
        case handedOver(wasRunning: Bool, wasPaused: Bool)
        /// The replacement could not start (bad PAT, transient network). The
        /// old engine is untouched and still owns the fleet.
        case rejected(String)
    }

    /// Replace this engine with `replacement` (built from a new config)
    /// without stopping any instance. The one ordering both the daemon and
    /// the app rebuild must follow, so no instance is ever driven by two
    /// engines at once:
    ///   1. verify the replacement's forges while this engine still owns the
    ///      fleet (nothing is adopted yet; a failure leaves this one serving),
    ///   2. detach and drain this engine,
    ///   3. only then let the replacement recover and start reconciling.
    /// A stopped fleet stays stopped, and a paused one stays paused.
    /// Callers must serialize hand-overs (the daemon's `EngineRef` gate).
    public func handOver(to replacement: FleetEngine) async -> HandOverResult {
        let previous = await status()
        let wasRunning = previous.running
        let wasPaused = previous.paused
        if wasRunning {
            replacement.markRunning()
            guard await replacement.prepareStart() else {
                let error = await replacement.status().lastError ?? "startup verification failed"
                return .rejected(error)
            }
        }
        await detachKeepingInstances()
        if wasRunning {
            await replacement.launch()
            if wasPaused { await replacement.setPaused(true) }
        }
        return .handedOver(wasRunning: wasRunning, wasPaused: wasPaused)
    }

    /// Wait for cancelled lifecycle tasks to exit, up to `timeout`. Shell
    /// commands ignore cancellation (they end on their own timeout), so a
    /// task blocked in one may outlive the bound; it then exits at its next
    /// cancellation check without touching the store, and the wait must not
    /// stall the reload RPC for the length of a registration script.
    func drain(_ tasks: [Task<Void, Never>], timeout: Duration) async {
        guard !tasks.isEmpty else { return }
        // A task group would wait for every child at scope exit (and awaiting
        // an unstructured task's value ignores cancellation), so race two
        // unstructured waiters and resume on whichever finishes first.
        let finished = Locked(0)
        let waiters = Locked<[Task<Void, Never>]>([])
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let pending = Locked<CheckedContinuation<Void, Never>?>(continuation)
            let resumeOnce: @Sendable () -> Void = {
                pending.withLock { slot in
                    defer { slot = nil }; return slot
                }?.resume()
            }
            let all = Task {
                for task in tasks {
                    await task.value
                    finished.withLock { $0 += 1 }
                }
                resumeOnce()
            }
            let timer = Task {
                do {
                    try await Task.sleep(for: timeout)
                    resumeOnce()
                } catch is CancellationError {
                    // The timer is cancelled once the wait is over; the slot
                    // has already been resumed, so there is nothing to do.
                    return
                } catch {
                    // A sleep failure must not stall the reload RPC.
                    resumeOnce()
                }
            }
            waiters.withLock { $0 = [all, timer] }
        }
        // The timer is the only waiter worth cancelling; the other ends with its tasks.
        waiters.withLock { $0.last }?.cancel()
        let stragglers = tasks.count - finished.withLock { $0 }
        if stragglers > 0 {
            Log.warn(
                "engine", "\(stragglers) lifecycle task(s) still in a shell command after detach; they exit on return")
        }
    }

    /// Swap in routing state from a freshly loaded config: the routing model
    /// (pools + routes), the capacity partition, the pool set, the named
    /// `images:` entries and the `projects:` rules. Callable while running —
    /// the next reconcile demand-buckets and spawns against the new shapes
    /// without a restart. Existing records keep their assigned runtime until
    /// they finish (teardown is per-record), so no instance is disrupted
    /// mid-job.
    ///
    /// Scope: routing and the label/image/project tables. A container-image
    /// change or a runtime's shape lives in the runtime instance (fixed per
    /// engine) and still needs a daemon restart.
    public func applyReloaded(config newConfig: KinhinConfig, host: HostResources) {
        let snapshot = Router.Snapshot.make(config: newConfig, host: host)
        router.replace(with: snapshot)
        // Fleet label edits must reach the forge's demand query too —
        // queuedJobs(matching:) filters by the forge's label set.
        forgeState.withLock { state in
            for (key, forge) in state.byPlatform {
                if let githubForge = forge as? GitHubForge {
                    state.byPlatform[key] = GitHubForge(
                        credentials: githubForge.credentials,
                        labels: newConfig.labels,
                        client: githubForge.client,
                        account: githubForge.account
                    )
                } else if let gitlabForge = forge as? GitLabForge {
                    // GitLab's demand filter is the labels the pools advertise.
                    state.byPlatform[key] = gitlabForge.replacingPoolLabels(snapshot.servedLabels)
                } else if var giteaForge = forge as? GiteaForge {
                    // Forgejo's queue endpoint matches jobs against the labels it is asked about.
                    giteaForge.poolLabels = snapshot.servedLabels
                    state.byPlatform[key] = giteaForge
                }
            }
        }
        let poolNames = snapshot.model.pools.keys.map(\.rawValue).sorted().joined(separator: ", ")
        let capNote = snapshot.caps.isEmpty ? "fleet cap" : "partitioned caps"
        Log.info("engine", "routing reloaded (pools: \(poolNames), \(capNote))")
        // New routes and labels re-bucket demand now, not after an idle backoff.
        pollSoon()
    }
}
