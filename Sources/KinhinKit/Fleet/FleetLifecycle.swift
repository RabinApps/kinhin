import Foundation
import Yams

// FleetEngine — per-VM/container lifecycle and EngineError.
extension FleetEngine {
    // MARK: - Lifecycle

    func spawnLifecycle(for record: VMRecord) {
        let existing = lifecycleLock.withLock { lifecycleTasks[record.id] }
        guard existing == nil else { return }

        let task = Task { [weak self] () -> Void in
            guard let self else { return }
            await self.runLifecycle(id: record.id)
        }
        lifecycleLock.withLock { lifecycleTasks[record.id] = task }
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
        lifecycleLock.withLock { lifecycleTasks[id] = nil }
    }

    func runLifecycle(id: String) async {
        defer { finishLifecycle(id: id) }
        do {
            // Resolve this record's runtime and pool (mixed fleets: per-record).
            var probe = VMRecord(id: id, phase: .cloning)
            probe.runtime = store.all.first { $0.id == id }?.runtime
            probe.poolLabels = store.all.first { $0.id == id }?.poolLabels
            let recordRuntime = runtime(for: probe)
            // Phase: provisioning (clone+boot for VMs, container run for
            // containers; idempotent for an existing id — recovery path).
            updateRecord(id) { $0.phase = .cloning }
            try await recordRuntime.provision(id: id, route: RepoRoute.from(config: config))
            try Task.checkCancellation()

            // Phase: booting. Runtimes return the address their registration
            // transport dials (Tart: the VM's IP for SSH); exec transports
            // (containers) return nil and register without one.
            updateRecord(id) { $0.phase = .booting }
            let ip: String? = try await recordRuntime.awaitReady(
                id: id,
                timeout: TimeInterval(config.vmBootTimeout)
            )
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
            guard let forge = forgesLock.withLock({ forgesByPlatform[account] }) else {
                throw EngineError.registrationFailed(
                    vm: id, stderr: "no \(account) forge attached (missing token?)")
            }
            let runnerCount = max(1, config.runnersPerVM)
            let result: ShellResult
            // Registration: the runtime produces the script flavor for the
            // forge and executes it through its own transport (SSH for VMs,
            // exec for containers) — the engine is transport-agnostic.
            let token: String
            switch forge.id {
            case .github:
                // Registration tokens expire hourly; each account has its own cache.
                token = try await registrationCache(for: account).token {
                    try await forge.mintRegistrationToken()
                }
            case .gitea, .forgejo:
                // Gitea and Forgejo tokens are long-lived, captured at forge
                // construction (Forgejo shares the Gitea runner and flow).
                guard let giteaFamilyForge = forge as? GiteaForge else {
                    throw EngineError.registrationFailed(vm: id, stderr: "gitea-family forge misconfigured")
                }
                token = giteaFamilyForge.registrationToken
            }
            let script = try await recordRuntime.registrationScript(
                forge: forge, token: token, name: id,
                runnerCount: runnerCount, route: RepoRoute.from(config: config),
                labels: poolLabels(for: probe)
            )
            result = try await recordRuntime.execRegistration(id, ip: ip, script, timeout: 600)
            guard result.succeeded else {
                throw EngineError.registrationFailed(vm: id, stderr: result.stderr)
            }
            Log.info(id, "runner registered")
            try Task.checkCancellation()

            // Phase: ready (or straight to busy if it picked up a job immediately)
            updateRecord(id) { $0.phase = .ready }

            // If ephemeral, watch until the runner deregisters itself, then delete.
            if config.vm.ephemeral {
                switch forge.id {
                case .github:
                    try await awaitEphemeralExit(id: id, ip: ip, forge: forge)
                case .gitea, .forgejo:
                    try await awaitGiteaExit(id: id, ip: ip, forge: forge)
                }
            }
        } catch is CancellationError {
            // Cancellation always originates from a path that owns teardown
            // (deleteVMRecord, scale-down, engine stop). Deleting here too
            // double-frees the VM and can resurrect the record mid-teardown.
            Log.info(id, "lifecycle cancelled")
        } catch {
            let message = (error as? LocalizedError)?.errorDescription ?? "\(error)"
            Log.error(id, "lifecycle failed: \(message)")
            updateRecord(id) {
                $0.phase = .failed
                $0.error = message
            }
        }
    }

    /// Gitea ephemeral watch: gitea-runner daemons do NOT deregister after a
    /// job (no --ephemeral), so "busy → idle for all runners" is the job-done
    /// signal; after a short grace period (in case the next task is already
    /// dispatching) the VM is deleted. Runners that never register trip the
    /// registration timeout, exactly like the GitHub path.
    func awaitGiteaExit(id: String, ip: String?, forge: Forge? = nil) async throws {
        let runnerCount = max(1, config.runnersPerVM)
        let expected: [String] =
            runnerCount == 1
            ? [id]
            : (1...runnerCount).map { "\(id)-r\($0)" }
        let deadline = Date().addingTimeInterval(TimeInterval(max(config.vmBootTimeout, 3600 * 6)))
        let registrationDeadline = Date().addingTimeInterval(TimeInterval(max(config.vmBootTimeout, 120)))
        let idleGrace: TimeInterval = 30
        var seen: Set<String> = []
        var idleSince: Date?
        while Date() < deadline {
            try Task.checkCancellation()
            let all: [ForgeRunner]
            if let forge = forge ?? forgesLock.withLock({ forgesByPlatform["gitea"] }) {
                do {
                    all = try await forge.runners()
                } catch {
                    // An API hiccup must not read as "runners deregistered",
                    // which would delete a VM that is still running a job.
                    Log.warn(id, "gitea runner list failed; retrying: \(error.localizedDescription)")
                    try await Task.sleep(for: .seconds(1))
                    continue
                }
            } else {
                all = []
            }
            let mine = all.filter { expected.contains($0.name) }
            for runner in mine { seen.insert(runner.name) }
            let allSeen = expected.allSatisfy { seen.contains($0) }

            if allSeen {
                if mine.isEmpty {
                    Log.info(id, "gitea runners deregistered; deleting VM")
                    await deleteVMRecord(id: id, reason: "jobs finished")
                    return
                }
                let anyBusy = mine.contains { $0.busy }
                if anyBusy {
                    idleSince = nil
                    updateRecord(id) { $0.phase = .busy }
                } else {
                    let since = idleSince ?? Date()
                    idleSince = since
                    if Date().timeIntervalSince(since) >= idleGrace {
                        Log.info(id, "gitea runners idle \(Int(idleGrace))s; job complete; deleting VM")
                        await deleteVMRecord(id: id, reason: "jobs finished")
                        return
                    }
                    updateRecord(id) { $0.phase = .ready }
                }
            } else if Date() > registrationDeadline {
                Log.warn(id, "gitea runners never registered; deleting VM")
                updateRecord(id) {
                    $0.phase = .failed
                    $0.error = "runner did not register within timeout"
                }
                await deleteVMRecord(id: id, reason: "registration timeout")
                return
            }
            try await Task.sleep(for: .seconds(1))
        }
        Log.warn(id, "gitea ephemeral watch timed out; deleting VM")
        await deleteVMRecord(id: id, reason: "timeout")
    }

    /// Wait for the VM's runner(s) to register, serve jobs, and deregister
    /// (the ephemeral flow). With `runners_per_vm > 1` the VM hosts several
    /// runners named `\(id)-r1…rN`. Every expected runner is tracked
    /// individually: the VM is deleted only when EVERY runner was seen
    /// registered at least once and NONE remain — partial deregistration
    /// (one runner's job finished) keeps the VM alive for the others. Runners
    /// that never register trip the registration timeout instead.
    func awaitEphemeralExit(id: String, ip: String?, forge: Forge? = nil) async throws {
        let runnerCount = max(1, config.runnersPerVM)
        let expected: [String] =
            runnerCount == 1
            ? [id]
            : (1...runnerCount).map { "\(id)-r\($0)" }
        func current(_ runners: [ForgeRunner]) -> [ForgeRunner] {
            runners.filter { expected.contains($0.name) }
        }
        /// The record's own account when known; the legacy client otherwise
        /// (tests and adopted VMs).
        func listRunners() async throws -> [ForgeRunner] {
            if let forge { return try await forge.runners() }
            return try await github.listRunners().map { ForgeRunner(id: $0.id, name: $0.name, busy: $0.busy) }
        }

        let deadline = Date().addingTimeInterval(TimeInterval(max(config.vmBootTimeout, 3600 * 6)))
        // Allowance for the agents inside the VM to finish registering.
        let registrationDeadline = Date().addingTimeInterval(TimeInterval(max(config.vmBootTimeout, 120)))
        var seen: Set<String> = []
        while Date() < deadline {
            try Task.checkCancellation()
            let mine = current(try await listRunners())
            for runner in mine {
                seen.insert(runner.name)
            }
            let allSeen = expected.allSatisfy { seen.contains($0) }

            if allSeen, mine.isEmpty {
                // Every runner completed its lifecycle; none remain on GitHub.
                let phase = store.all.first { $0.id == id }?.phase
                if phase == .busy {
                    Log.info(id, "all jobs finished; runners deregistered; deleting VM")
                    await deleteVMRecord(id: id, reason: "jobs finished")
                } else {
                    Log.warn(id, "runners vanished while ready; deleting VM")
                    await deleteVMRecord(id: id, reason: "runners vanished")
                }
                return
            }

            if !mine.isEmpty {
                let anyBusy = mine.contains { $0.busy }
                updateRecord(id) { $0.phase = anyBusy ? .busy : .ready }
            } else if Date() > registrationDeadline {
                // Some runner(s) never registered at all.
                Log.warn(id, "runners never registered on GitHub; deleting VM")
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

    func deleteVMRecord(id: String, reason: String) async {
        Log.info(id, "deleting VM (\(reason))")
        updateRecord(id) { $0.phase = .deleting }
        let task = lifecycleLock.withLock { lifecycleTasks[id] }
        task?.cancel()

        // Clean up any lingering runner registrations for this VM on every
        // attached forge — the VM id itself, or its indexed runners (\(id)-rN).
        let attached = forgesLock.withLock { Array(forgesByPlatform.values) }
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

    func runTelemetryIfPossible(_ id: String) async {}

    func pauseAllVMs() async {
        let tasks = lifecycleLock.withLock { () -> [Task<Void, Never>] in
            let tasks = Array(lifecycleTasks.values)
            lifecycleTasks.removeAll()
            return tasks
        }
        for task in tasks {
            task.cancel()
        }
        // Give tasks a moment to clean their VMs up. Cancellation here only
        // shortens the grace period; the sweep below still runs.
        try? await Task.sleep(for: .seconds(2))
        let remaining = store.all.filter { $0.phase.isActive }
        for record in remaining {
            await deleteVMRecord(id: record.id, reason: "engine stopped")
        }
    }
}
