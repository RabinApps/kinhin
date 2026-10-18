import Foundation
import Yams

// FleetEngine — per-VM/container lifecycle.
extension FleetEngine {
    // MARK: - Lifecycle

    /// The instance whose lifecycle task is running the current code (nil
    /// outside a lifecycle task). `deleteVMRecord` reads it so a lifecycle
    /// deleting its own instance does not cancel itself mid-cleanup.
    @TaskLocal static var currentLifecycleID: String?

    func spawnLifecycle(for record: VMRecord) {
        spawnLifecycleTask(id: record.id) { [weak self] in
            await self?.runLifecycle(id: record.id)
        }
    }

    /// Binds a warm instance to `account` and registers it: the clone and boot are already done.
    func claimWarm(id: String, account: String) {
        var claimed: VMRecord?
        store.update(id: id) { record in
            guard record.phase == .warm else { return }
            record.platform = account
            record.pooled = nil
            record.phase = .registering
            claimed = record
        }
        guard claimed != nil else { return }
        Log.info(id, "claimed warm instance for \(account)")
        spawnLifecycleTask(id: id) { [weak self] in
            await self?.runLifecycle(id: id, claimed: true)
        }
    }

    /// Re-enter an instance's lifecycle after a restart or engine hand-over.
    /// An instance that already registered (`ready`/`busy`) must not replay
    /// provisioning and registration: re-registering a classic runner removes
    /// it mid-job, and a scale-set JIT request for an existing runner name is
    /// rejected, which would fail the record and delete a busy VM. Those
    /// instances go straight back to watching their runner.
    func resumeLifecycle(for record: VMRecord) {
        // A warm instance is already booted and waits to be claimed: no task, nothing to replay.
        if record.phase == .warm { return }
        guard record.phase == .ready || record.phase == .busy else {
            spawnLifecycle(for: record)
            return
        }
        let account = record.platform ?? ForgeID.github.rawValue
        guard let forge = forgeState.withLock({ $0.byPlatform[account] }) else {
            // Nothing to watch it with: the full lifecycle fails the record
            // ("no forge attached") and the normal cleanup removes it.
            spawnLifecycle(for: record)
            return
        }
        let watchesExit =
            config.vm.ephemeral
            || { if case .jitConfig = forge.registration { return true } else { return false } }()
        guard watchesExit else {
            // A classic persistent runner is not tracked after registration, so nothing would ever move a busy
            // phase back. Scale-down confirms idleness against the forge before it removes one, so `ready` is safe.
            updateRecord(record.id) { $0.phase = .ready }
            return
        }
        let id = record.id
        Log.info(id, "resuming exit watch for \(record.phase.rawValue) instance")
        spawnLifecycleTask(id: id) { [weak self] in
            guard let self else { return }
            defer { self.finishLifecycle(id: id) }
            do {
                try await self.awaitRunnerExit(id: id, forge: forge)
            } catch {
                if error is CancellationError || Task.isCancelled { return }
                Log.error(id, "exit watch failed: \(error.localizedDescription)")
            }
        }
    }

    /// Start `body` as the lifecycle task for `id` (no-op when one is already
    /// running). Check, create and insert happen under one lock: a concurrent
    /// spawn cannot start a second task, and the task's own finishLifecycle
    /// cannot run before the entry exists (which would leave a stale entry).
    func spawnLifecycleTask(id: String, body: @escaping @Sendable () async -> Void) {
        lifecycleTasks.withLock { tasks in
            guard tasks[id] == nil else { return }
            tasks[id] = Task {
                await Self.$currentLifecycleID.withValue(id) { await body() }
            }
        }
    }

    func updateRecord(_ id: String, mutate: (inout VMRecord) -> Void) {
        // A record deleted concurrently (manual delete, scale-down, engine
        // stop) is never resurrected from a racing lifecycle task, and a
        // mutation that changes nothing (the exit watch re-asserting the
        // current phase every second) costs no write.
        store.update(id: id, mutate)
    }

    func finishLifecycle(id: String) {
        lifecycleTasks.withLock { $0[id] = nil }
    }

    func runLifecycle(id: String, claimed: Bool = false) async {
        defer { finishLifecycle(id: id) }
        do {
            // Resolve this record's runtime and pool (mixed fleets: per-record).
            var probe = VMRecord(id: id, phase: .cloning)
            let stored = store.all.first { $0.id == id }
            probe.runtime = stored?.runtime
            probe.image = stored?.image
            let recordRuntime = runtime(for: probe)
            let ip: String?
            if claimed {
                // A claimed warm instance is booted and pinned; only registration is left.
                ip = stored?.ip
            } else {
                // A freshly spawned instance waits its turn so a burst of clones does not stampede the
                // disk; a re-entered one (recovery) is already on the host and starts at once.
                if stored?.phase == .cloning { try await spawnPacer.admit() }
                // Phase: provisioning (clone+boot for VMs, container run for
                // containers; idempotent for an existing id — recovery path).
                updateRecord(id) { $0.phase = .cloning }
                try await recordRuntime.provision(id: id, route: route(forRecord: id))
                try Task.checkCancellation()

                // Phase: booting. Runtimes return the address their registration
                // transport dials (Tart: the VM's IP for SSH); exec transports
                // (containers) return nil and register without one.
                updateRecord(id) { $0.phase = .booting }
                let bootedIP: String? = try await recordRuntime.awaitReady(
                    id: id,
                    timeout: TimeInterval(config.vmBootTimeout)
                )
                // After every awaited runtime/forge call: a detached engine's
                // straggler must exit here, never write to the store.
                try Task.checkCancellation()
                updateRecord(id) { $0.ip = bootedIP }
                if let bootedIP {
                    Log.info(id, "booted at \(bootedIP)")
                } else {
                    Log.info(id, "instance ready (exec transport)")
                }
                // A pool instance stops here, booted and waiting to be claimed.
                if store.all.first(where: { $0.id == id })?.pooled == true {
                    updateRecord(id) { $0.phase = .warm }
                    Log.info(id, "warm")
                    return
                }
                ip = bootedIP
            }

            // Phase: registering — platform- and runtime-specific bootstrap.
            // The platform was assigned at spawn (token-gated: forges only
            // exist when their credential exists), defaulting to GitHub for
            // adopted VMs. The runtime produces the right script flavor
            // (macOS VM scripts vs Linux container scripts) for its id.
            updateRecord(id) { $0.phase = .registering }
            let account = store.all.first { $0.id == id }?.platform ?? ForgeID.github.rawValue
            guard let forge = forgeState.withLock({ $0.byPlatform[account] }) else {
                throw EngineError.registrationFailed(
                    vm: id, stderr: "no \(account) forge attached (missing token?)")
            }
            let runnerCount = max(1, config.runnersPerVM)
            let result: ShellResult
            // Registration: the runtime produces the script flavor for the
            // forge and executes it through its own transport (SSH for VMs,
            // exec for containers) — the engine is transport-agnostic.
            let labels = poolLabels(for: probe)
            let isScaleSet = if case .jitConfig = forge.registration { true } else { false }
            let token: String
            var runnerTokens: [String: String] = [:]
            switch forge.registration {
            case .sharedShortLived:
                // Registration tokens expire hourly; each account has its own cache.
                guard !isScaleSet else {
                    throw EngineError.registrationFailed(vm: id, stderr: "scale-set forge requires JIT registration")
                }
                token = try await registrationCache(for: account).token(fetchExpiring: {
                    try await forge.mintRegistrationTokenExpiring()
                })
            case .sharedLongLived:
                // Long-lived (Gitea family): captured at forge construction.
                guard !isScaleSet else {
                    throw EngineError.registrationFailed(vm: id, stderr: "scale-set forge requires JIT registration")
                }
                token = try await forge.mintRegistrationToken()
            case .perRunner:
                // Each runner is created on the forge now, with its own token.
                guard !isScaleSet else {
                    throw EngineError.registrationFailed(vm: id, stderr: "scale-set forge requires JIT registration")
                }
                token = ""
                runnerTokens = try await forge.registrationTokens(
                    runnerNames: Self.runnerNames(for: id, count: runnerCount), labels: labels ?? [])
            case .jitConfig:
                guard isScaleSet else {
                    throw EngineError.registrationFailed(vm: id, stderr: "JIT registration requires a scale-set forge")
                }
                // GitHub Runner Scale Set runners authenticate with a JIT config
                // generated per runner by the scale-set message API. The engine
                // asks the forge for one config per named runner and passes each
                // encoded config to the in-VM bootstrap.
                token = ""
                runnerTokens = try await forge.jitRunnerTokens(
                    names: Self.runnerNames(for: id, count: runnerCount), labels: labels ?? [])
                guard runnerTokens.count == runnerCount else {
                    throw EngineError.registrationFailed(vm: id, stderr: "forge returned incomplete JIT configs")
                }
            }
            // Registration material can surface in a failed script's output or a
            // forge error body; most of it has no prefix the redaction rules know.
            for secret in [token] + runnerTokens.values { LogRedactor.registerRegistrationSecret(secret) }
            try Task.checkCancellation()
            let script = try await recordRuntime.registrationScript(
                forge: forge, token: token, runnerTokens: runnerTokens, name: id,
                runnerCount: runnerCount, route: route(forRecord: id),
                labels: labels
            )
            result = try await recordRuntime.execRegistration(id, ip: ip, script, timeout: 600)
            try Task.checkCancellation()
            guard result.succeeded else {
                // Some bootstrap tools (the runner's config.sh) report errors on stdout.
                let detail = result.stderr.isEmpty ? result.stdout : result.stderr
                throw EngineError.registrationFailed(vm: id, stderr: "exit \(result.exitCode): \(detail)")
            }
            Log.info(id, "registration script finished")

            // Phase: ready (or straight to busy if it picked up a job immediately)
            updateRecord(id) { $0.phase = .ready }

            // Scale-set runners are always one-job ephemeral, independent of
            // the fleet-wide classic-runner setting.
            if config.vm.ephemeral || isScaleSet {
                // The watch clears the spawn backoff once the runner is seen online.
                try await awaitRunnerExit(id: id, forge: forge)
            } else {
                // Nothing watches a classic runner: the script finishing is all the signal there is.
                noteSpawnSuccess(id)
            }
        } catch is CancellationError {
            // Cancellation always originates from a path that owns teardown
            // (deleteVMRecord, scale-down, engine stop). Deleting here too
            // double-frees the VM and can resurrect the record mid-teardown.
            Log.info(id, "lifecycle cancelled")
        } catch  where Task.isCancelled {
            // Cancelled mid-call surfaces as the callee's own error (e.g.
            // URLError.cancelled from the runner list). Marking the record
            // failed would make a replacement engine delete a busy VM.
            Log.info(id, "lifecycle cancelled (\(error.localizedDescription))")
        } catch {
            let message = (error as? LocalizedError)?.errorDescription ?? "\(error)"
            Log.error(id, "lifecycle failed: \(message)")
            updateRecord(id) {
                $0.phase = .failed
                $0.error = message
            }
        }
    }

    /// Watch an ephemeral instance's runner(s) until their job is done, then
    /// delete it. With `runners_per_vm > 1` the instance hosts several runners
    /// named `\(id)-r1…rN`; each is tracked individually, and the instance is
    /// deleted only once EVERY runner was seen registered and then either:
    ///
    /// - `.deregisters` (GitHub, GitLab): none remain on the forge — partial
    ///   deregistration (one runner's job finished) keeps it alive for the
    ///   others;
    /// - `.idleGrace` (Gitea family): gitea-runner daemons do NOT deregister
    ///   after a job, so "busy → idle for all runners" for a short grace
    ///   period (in case the next task is already dispatching) is the signal.
    ///
    /// Runners that never register trip the registration timeout. A failed
    /// runner list is retried: an API hiccup must never read as "runners
    /// deregistered", which would delete an instance mid-job.
    func awaitRunnerExit(id: String, forge: Forge) async throws {
        let expected = Self.runnerNames(for: id, count: config.runnersPerVM)
        let forgeName = forge.name
        let idleGrace: TimeInterval? = forge.exitSemantics == .idleGrace ? watchdog.idleGrace.timeInterval : nil
        let isScaleSetForge = if case .jitConfig = forge.registration { true } else { false }
        let deadline = Date().addingTimeInterval(TimeInterval(max(config.vmBootTimeout, 3600 * 6)))
        // Allowance for the agents inside the instance to finish registering.
        let registrationDeadline = Date().addingTimeInterval(
            max(TimeInterval(config.vmBootTimeout), watchdog.registrationGrace.timeInterval))
        var seen: Set<String> = []
        // Runners that were ever listed, online or not. A runner that appeared
        // and then vanished completed its lifecycle even when no poll caught it
        // online (a short job finishes between two reads of the shared list).
        var appeared: Set<String> = []
        // Runners the forge's event stream says ran a job and finished it: a short job can start
        // and end between two list reads, so this is the only sign some runners leave.
        var reportedFinished: Set<String> = []
        var idleSince: Date?
        // The runtime is asked less often than the forge: a dead instance
        // otherwise waits out the deadline below (hours) with its record.
        var lastLivenessCheck = ContinuousClock.now
        var deadChecks = 0
        var reportedOnline = false
        // The watch reads the shared (up to a few seconds old) runner list, but
        // never deletes on it: each decision below is confirmed against the
        // forge itself, so a stale "gone" or "idle" cannot kill a busy instance.
        func confirmedRunners() async throws -> [ForgeRunner]? {
            do {
                return try await observedRunners(of: forge, expected: expected, fresh: true)
            } catch let error where !(error is CancellationError) && !Task.isCancelled {
                Log.warn(id, "\(forgeName) runner list failed; retrying: \(error.localizedDescription)")
                return nil
            }
        }
        while Date() < deadline {
            try Task.checkCancellation()
            let mine: [ForgeRunner]
            do {
                mine = try await observedRunners(of: forge, expected: expected, fresh: false)
            } catch let error where !(error is CancellationError) && !Task.isCancelled {
                Log.warn(id, "\(forgeName) runner list failed; retrying: \(error.localizedDescription)")
                try await Task.sleep(for: exitWatchInterval)
                continue
            }
            // A detached engine's watcher must not delete or re-phase the instance.
            try Task.checkCancellation()
            for runner in mine where runner.online { seen.insert(runner.name) }
            for runner in mine { appeared.insert(runner.name) }
            if idleGrace == nil, !expected.allSatisfy({ appeared.contains($0) }) {
                let finished = await forge.runnersReportedFinished(expected)
                reportedFinished.formUnion(finished)
                appeared.formUnion(finished)
                if !finished.isEmpty, !reportedOnline {
                    reportedOnline = true
                    noteSpawnSuccess(id)
                }
            }
            // A runner that came online proves the start worked; a script that
            // merely exited 0 does not (the agent can die right after).
            if !reportedOnline, !seen.isEmpty {
                reportedOnline = true
                noteSpawnSuccess(id)
            }
            let allSeen = expected.allSatisfy { seen.contains($0) }
            // Deregistering forges: a listed-then-gone runner is a finished
            // one. Idle-grace forges never remove their runners, so for them
            // only a runner seen online can have finished.
            let allFinished = allSeen || (idleGrace == nil && expected.allSatisfy { appeared.contains($0) })

            if allFinished, mine.isEmpty {
                guard let confirmed = try await confirmedRunners(), confirmed.isEmpty else {
                    try await Task.sleep(for: exitWatchInterval)
                    continue
                }
                // Every runner completed its lifecycle; none remain.
                let phase = store.all.first { $0.id == id }?.phase
                if phase == .busy || idleGrace != nil || !reportedFinished.isEmpty {
                    Log.info(id, "all jobs finished; \(forgeName) runners deregistered; deleting VM")
                    await deleteVMRecord(id: id, reason: "jobs finished")
                } else {
                    if isScaleSetForge {
                        // A scale-set runner is ephemeral and only disappears early when GitHub
                        // removed it: the job it was reserved for was cancelled before pickup.
                        Log.info(id, "runner removed on GitHub before taking a job (cancelled?); deleting VM")
                        await deleteVMRecord(id: id, reason: "cancelled remotely")
                    } else {
                        Log.warn(id, "runners vanished while ready; deleting VM")
                        await deleteVMRecord(id: id, reason: "runners vanished")
                    }
                }
                return
            }
            if !mine.isEmpty {
                if mine.contains(where: \.busy) {
                    idleSince = nil
                    updateRecord(id) { $0.phase = .busy }
                } else {
                    updateRecord(id) { $0.phase = .ready }
                    if let idleGrace, allSeen {
                        let since = idleSince ?? Date()
                        idleSince = since
                        if Date().timeIntervalSince(since) >= idleGrace {
                            guard let confirmed = try await confirmedRunners(), !confirmed.contains(where: \.busy)
                            else {
                                idleSince = nil
                                try await Task.sleep(for: exitWatchInterval)
                                continue
                            }
                            Log.info(id, "\(forgeName) runners idle \(Int(idleGrace))s; job complete; deleting VM")
                            await deleteVMRecord(id: id, reason: "jobs finished")
                            return
                        }
                    }
                }
            }
            // Deregistering forges wait while some runners are up; idle-grace
            // forges need every runner registered to judge idleness at all.
            // A runner listed but never online (the forge made the record, the
            // agent never started) is not "up": it must not hold the instance
            // past the registration deadline.
            let nobodyOnline = !mine.contains(where: \.online)
            if !allSeen, nobodyOnline || idleGrace != nil, Date() > registrationDeadline {
                guard let confirmed = try await confirmedRunners() else {
                    try await Task.sleep(for: exitWatchInterval)
                    continue
                }
                for runner in confirmed where runner.online { seen.insert(runner.name) }
                guard !expected.allSatisfy({ seen.contains($0) }) else { continue }
                Log.warn(id, "runners never registered on \(forgeName); deleting VM")
                // Counted here: the delete below removes the record before the
                // reconcile pass could see it `.failed` and note the failure.
                noteSpawnFailure(
                    runtime: recordedRuntime(of: id), reason: "runner did not register within timeout")
                await deleteVMRecord(id: id, reason: "registration timeout")
                return
            }
            if ContinuousClock.now - lastLivenessCheck >= watchdog.livenessInterval {
                lastLivenessCheck = ContinuousClock.now
                switch await liveness(of: id) {
                case .alive: deadChecks = 0
                case .unknown: break
                case .dead(let state):
                    deadChecks += 1
                    if deadChecks >= watchdog.livenessMisses {
                        let phase = store.all.first { $0.id == id }?.phase.rawValue ?? "unknown"
                        Log.error(
                            id,
                            "instance is \(state == .gone ? "gone" : "stopped") while its runner was \(phase); cleaning up"
                        )
                        await deleteVMRecord(id: id, reason: "instance \(state == .gone ? "gone" : "stopped")")
                        return
                    }
                }
            }
            try await Task.sleep(for: exitWatchInterval)
        }
        Log.warn(id, "ephemeral watch timed out; deleting VM")
        await deleteVMRecord(id: id, reason: "timeout")
    }

    /// The expected runners as the forge shows them. A server with no runner
    /// list (Forgejo through v14) cannot say which runner runs what, so each
    /// expected runner is reported registered (its registration script
    /// succeeded before the watch began) and busy exactly while any task of
    /// the scope is running. That keeps the rule safe: an instance is only
    /// ever judged idle when nothing at all is running in the scope, and a
    /// runner that never got a job is reclaimed the same way, once the scope
    /// goes quiet. `fresh` asks the forge itself (before acting on idleness).
    func observedRunners(of forge: Forge, expected: [String], fresh: Bool) async throws -> [ForgeRunner] {
        let all =
            fresh
            ? try await runnerDirectory.freshRunners(of: forge)
            : try await runnerDirectory.runners(of: forge)
        // Asked after the list: that call is what discovers the list is absent.
        if let running = try await forge.unlistedRunnerActivity(fresh: fresh) {
            return expected.map { ForgeRunner(id: $0, name: $0, busy: running > 0) }
        }
        return all.filter { expected.contains($0.name) }
    }

    /// The runtime recorded for `id` (the default pool's when unrecorded).
    func recordedRuntime(of id: String) -> RuntimeID {
        store.all.first { $0.id == id }?.runtimeID ?? routing.defaultRuntime
    }

    /// A runner of `id` registered: its runtime's spawn backoff clears.
    func noteSpawnSuccess(_ id: String) {
        let runtime = recordedRuntime(of: id)
        spawnBackoff.withLock { $0.recordSuccess(runtime) }
    }

    /// The runner names an instance registers: the instance id itself, or
    /// `\(id)-r1…rN` when it hosts several runners.
    static func runnerNames(for id: String, count: Int) -> [String] {
        let count = max(1, count)
        return count == 1 ? [id] : (1...count).map { "\(id)-r\($0)" }
    }

    func deleteVMRecord(id: String, reason: String) async {
        guard deletes.withLock({ $0.inFlight.insert(id).inserted }) else { return }
        defer { deletes.withLock { _ = $0.inFlight.remove(id) } }
        Log.info(id, "deleting VM (\(reason))")
        updateRecord(id) { $0.phase = .deleting }
        // Stop the instance's lifecycle — unless that lifecycle is the caller
        // (its exit watcher deleting a finished VM): cancelling ourselves
        // would fail the runner cleanup below, silently, on cancellation.
        if Self.currentLifecycleID != id {
            let task = lifecycleTasks.withLock { $0[id] }
            task?.cancel()
        }

        // Clean up any lingering runner registrations for this VM on every
        // attached forge — the VM id itself, or its indexed runners (\(id)-rN).
        let attached = forgeState.withLock { Array($0.byPlatform.values) }
        for forge in attached {
            await bestEffortAsync(id, "cleaning up stale runner registrations") {
                let stale = try await runnerDirectory.freshRunners(of: forge).filter {
                    $0.name == id || $0.name.hasPrefix("\(id)-r")
                }
                for runner in stale {
                    await bestEffortAsync(id, "deleting runner \(runner.name)") {
                        try await forge.deleteRunner(id: runner.id)
                    }
                }
            }
        }
        // Runtime teardown (per-record: stop+delete the VM, or container rm).
        var probe = VMRecord(id: id, phase: .deleting)
        probe.runtime = store.all.first { $0.id == id }?.runtime
        do {
            try await runtime(for: probe).teardown(id: id)
        } catch is CancellationError {
            // The instance may still exist: keep the record in `.deleting` so the
            // reconcile pass (or the next start) finishes the idempotent teardown.
            Log.info(id, "teardown interrupted; will retry")
            return
        } catch {
            // Keep the record in `.deleting`: dropping it would leave an
            // untracked instance eating disk. The reconcile pass retries it.
            let message = (error as? LocalizedError)?.errorDescription ?? "\(error)"
            Log.error(id, "teardown failed; will retry: \(message)")
            updateRecord(id) { $0.error = "teardown failed: \(message)" }
            return
        }
        store.remove(id: id)
        Log.info(id, "VM deleted")
    }

    // MARK: - Background deletes

    /// Tears `id` down in its own task and returns at once, so a reconcile pass never waits on a
    /// teardown (each can take minutes: a stop and a delete, up to 120 s each). Single-flight per
    /// instance: false when a delete of `id` is already running or scheduled. The pass sees the
    /// record's `.deleting` phase (or its removal) on a later turn; `settleDeletes` waits for them.
    @discardableResult
    func scheduleDelete(id: String, reason: String) -> Bool {
        deletes.withLock { state in
            guard state.tasks[id] == nil, !state.inFlight.contains(id) else { return false }
            // The task removes itself under this same lock, so it cannot finish before it is stored.
            state.tasks[id] = Task { [weak self] in
                await self?.deleteVMRecord(id: id, reason: reason)
                self?.deletes.withLock { $0.tasks[id] = nil }
            }
            return true
        }
    }

    /// Waits for every scheduled delete, up to `timeout` (nil: as long as it takes).
    func settleDeletes(timeout: Duration? = nil) async {
        let tasks = deletes.withLock { Array($0.tasks.values) }
        if let timeout {
            await drain(tasks, timeout: timeout)
        } else {
            for task in tasks { await task.value }
        }
    }

    /// Instances torn down at once when the engine stops.
    static let stopDeleteConcurrency = 8
    /// How long `stop()` waits for those teardowns. The RPC handler gives a call 120 s; the stop must
    /// answer inside it. Whatever is still tearing down keeps running in the background and, if the
    /// process exits first, is finished by the next start (the record stays `.deleting`).
    static let stopDeleteBudget: Duration = .seconds(100)

    /// Engine stop: cancels every lifecycle and deletes every active instance, up to
    /// `stopDeleteConcurrency` at a time, within `stopDeleteBudget` in total.
    func deleteAllActiveVMs(budget: Duration = FleetEngine.stopDeleteBudget) async {
        let tasks = lifecycleTasks.withLock { tasks -> [Task<Void, Never>] in
            defer { tasks.removeAll() }
            return Array(tasks.values)
        }
        for task in tasks {
            task.cancel()
        }
        // Give tasks a moment to clean their VMs up. Cancellation here only
        // shortens the grace period; the sweep below still runs. Nothing to
        // wait for when no lifecycle task was running.
        if !tasks.isEmpty {
            do {
                try await Task.sleep(for: .seconds(2))
            } catch is CancellationError {
                // Stop waiting early, but still sweep below.
            } catch {
                Log.warn("engine", "stop-grace sleep failed: \(error.localizedDescription)")
            }
        }
        let remaining = store.all.filter { $0.phase.isActive }.map(\.id)
        let sweep = Task {
            do {
                _ = try await boundedMap(remaining, limit: Self.stopDeleteConcurrency) { id in
                    await self.deleteVMRecord(id: id, reason: "engine stopped")
                }
            } catch {
                Log.warn("engine", "stop sweep interrupted: \(error.localizedDescription)")
            }
        }
        let background = deletes.withLock { Array($0.tasks.values) }
        await drain([sweep] + background, timeout: budget)
    }
}
