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
        guard var record = store.all.first(where: { $0.id == id }) else {
            // The record was deleted concurrently (manual delete, scale-down,
            // engine stop). Never resurrect it from a racing lifecycle task.
            return
        }
        mutate(&record)
        record.updatedAt = Date()
        store.upsert(record)
    }

    func finishLifecycle(id: String) {
        lifecycleTasks.withLock { $0[id] = nil }
    }

    func runLifecycle(id: String) async {
        defer { finishLifecycle(id: id) }
        do {
            // Resolve this record's runtime and pool (mixed fleets: per-record).
            var probe = VMRecord(id: id, phase: .cloning)
            let stored = store.all.first { $0.id == id }
            probe.runtime = stored?.runtime
            probe.image = stored?.image
            let recordRuntime = runtime(for: probe)
            // Phase: provisioning (clone+boot for VMs, container run for
            // containers; idempotent for an existing id — recovery path).
            updateRecord(id) { $0.phase = .cloning }
            try await recordRuntime.provision(id: id, route: route(forRecord: id))
            try Task.checkCancellation()

            // Phase: booting. Runtimes return the address their registration
            // transport dials (Tart: the VM's IP for SSH); exec transports
            // (containers) return nil and register without one.
            updateRecord(id) { $0.phase = .booting }
            let ip: String? = try await recordRuntime.awaitReady(
                id: id,
                timeout: TimeInterval(config.vmBootTimeout)
            )
            // After every awaited runtime/forge call: a detached engine's
            // straggler must exit here, never write to the store.
            try Task.checkCancellation()
            updateRecord(id) { $0.ip = ip }
            if let ip {
                Log.info(id, "booted at \(ip)")
            } else {
                Log.info(id, "instance ready (exec transport)")
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
            let token: String
            var runnerTokens: [String: String] = [:]
            switch forge.registration {
            case .sharedShortLived:
                // Registration tokens expire hourly; each account has its own cache.
                token = try await registrationCache(for: account).token {
                    try await forge.mintRegistrationToken()
                }
            case .sharedLongLived:
                // Long-lived (Gitea family): captured at forge construction.
                token = try await forge.mintRegistrationToken()
            case .perRunner:
                // Each runner is created on the forge now, with its own token.
                token = ""
                runnerTokens = try await forge.registrationTokens(
                    runnerNames: Self.runnerNames(for: id, count: runnerCount), labels: labels ?? [])
            }
            try Task.checkCancellation()
            let script = try await recordRuntime.registrationScript(
                forge: forge, token: token, runnerTokens: runnerTokens, name: id,
                runnerCount: runnerCount, route: route(forRecord: id),
                labels: labels
            )
            result = try await recordRuntime.execRegistration(id, ip: ip, script, timeout: 600)
            try Task.checkCancellation()
            guard result.succeeded else {
                throw EngineError.registrationFailed(vm: id, stderr: result.stderr)
            }
            Log.info(id, "runner registered")

            // Phase: ready (or straight to busy if it picked up a job immediately)
            updateRecord(id) { $0.phase = .ready }

            // If ephemeral, watch until the runner deregisters itself, then delete.
            if config.vm.ephemeral {
                try await awaitRunnerExit(id: id, forge: forge)
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
        let idleGrace: TimeInterval? = forge.exitSemantics == .idleGrace ? 30 : nil
        let deadline = Date().addingTimeInterval(TimeInterval(max(config.vmBootTimeout, 3600 * 6)))
        // Allowance for the agents inside the instance to finish registering.
        let registrationDeadline = Date().addingTimeInterval(TimeInterval(max(config.vmBootTimeout, 120)))
        var seen: Set<String> = []
        var idleSince: Date?
        while Date() < deadline {
            try Task.checkCancellation()
            let all: [ForgeRunner]
            do {
                all = try await forge.runners()
            } catch let error where !(error is CancellationError) && !Task.isCancelled {
                Log.warn(id, "\(forgeName) runner list failed; retrying: \(error.localizedDescription)")
                try await Task.sleep(for: .seconds(1))
                continue
            }
            // A detached engine's watcher must not delete or re-phase the instance.
            try Task.checkCancellation()
            let mine = all.filter { expected.contains($0.name) }
            for runner in mine where runner.online { seen.insert(runner.name) }
            let allSeen = expected.allSatisfy { seen.contains($0) }

            if allSeen, mine.isEmpty {
                // Every runner completed its lifecycle; none remain.
                let phase = store.all.first { $0.id == id }?.phase
                if phase == .busy || idleGrace != nil {
                    Log.info(id, "all jobs finished; \(forgeName) runners deregistered; deleting VM")
                    await deleteVMRecord(id: id, reason: "jobs finished")
                } else {
                    Log.warn(id, "runners vanished while ready; deleting VM")
                    await deleteVMRecord(id: id, reason: "runners vanished")
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
                            Log.info(id, "\(forgeName) runners idle \(Int(idleGrace))s; job complete; deleting VM")
                            await deleteVMRecord(id: id, reason: "jobs finished")
                            return
                        }
                    }
                }
            }
            // Deregistering forges wait while some runners are up; idle-grace
            // forges need every runner registered to judge idleness at all.
            if !allSeen, mine.isEmpty || idleGrace != nil, Date() > registrationDeadline {
                Log.warn(id, "runners never registered on \(forgeName); deleting VM")
                updateRecord(id) {
                    $0.phase = .failed
                    $0.error = "runner did not register within timeout"
                }
                await deleteVMRecord(id: id, reason: "registration timeout")
                return
            }
            try await Task.sleep(for: .seconds(1))
        }
        Log.warn(id, "ephemeral watch timed out; deleting VM")
        await deleteVMRecord(id: id, reason: "timeout")
    }

    /// The runner names an instance registers: the instance id itself, or
    /// `\(id)-r1…rN` when it hosts several runners.
    static func runnerNames(for id: String, count: Int) -> [String] {
        let count = max(1, count)
        return count == 1 ? [id] : (1...count).map { "\(id)-r\($0)" }
    }

    func deleteVMRecord(id: String, reason: String) async {
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
                let stale = try await forge.runners().filter { $0.name == id || $0.name.hasPrefix("\(id)-r") }
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
        await runtime(for: probe).teardown(id: id)
        store.remove(id: id)
        Log.info(id, "VM deleted")
    }

    func pauseAllVMs() async {
        let tasks = lifecycleTasks.withLock { tasks -> [Task<Void, Never>] in
            defer { tasks.removeAll() }
            return Array(tasks.values)
        }
        for task in tasks {
            task.cancel()
        }
        // Give tasks a moment to clean their VMs up. Cancellation here only
        // shortens the grace period; the sweep below still runs.
        do {
            try await Task.sleep(for: .seconds(2))
        } catch is CancellationError {
            // Stop waiting early, but still sweep below.
        } catch {
            Log.warn("engine", "stop-grace sleep failed: \(error.localizedDescription)")
        }
        let remaining = store.all.filter { $0.phase.isActive }
        for record in remaining {
            await deleteVMRecord(id: record.id, reason: "engine stopped")
        }
    }
}
