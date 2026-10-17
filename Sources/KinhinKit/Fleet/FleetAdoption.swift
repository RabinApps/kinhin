import Foundation

// MARK: - Adoption (restart recovery)

extension FleetEngine {
    /// Re-enters an instance a restart found on its runtime. Registration is
    /// replayed only when the forge has no runner for it: registering replaces
    /// a runner by name (`config.sh --replace`) or is rejected for an existing
    /// JIT name, so replaying it on a VM that is mid-job fails that job. A
    /// runner the forge already has is watched instead, busy or idle. A forge
    /// that cannot answer holds the instance (see `holdAdoption`) rather than guess.
    func resumeAdopted(_ record: VMRecord) async {
        // Instances the engine already drove keep their phase-based path, and
        // a pooled VM never registers (it waits warm), so neither asks the forge.
        guard record.phase != .ready, record.phase != .busy, record.pooled != true else {
            resumeLifecycle(for: record)
            return
        }
        let id = record.id
        let account = record.platform ?? ForgeID.github.rawValue
        guard let forge = forgeState.withLock({ $0.byPlatform[account] }) else {
            await holdAdoption(id, reason: "no \(account) forge attached yet")
            return
        }
        let expected = Self.runnerNames(for: id, count: config.runnersPerVM)
        let runners: [ForgeRunner]
        do {
            // Fresh: a stale list could miss a runner registered just before the restart.
            runners = try await observedRunners(of: forge, expected: expected, fresh: true)
        } catch is CancellationError {
            return
        } catch {
            await holdAdoption(id, reason: "could not read \(forge.name) runners: \(error.localizedDescription)")
            return
        }
        pendingAdoptions.withLock { _ = $0.remove(id) }
        guard !runners.isEmpty else {
            Log.info(id, "no runner on \(forge.name): registering it")
            spawnLifecycle(for: record)
            return
        }
        // Any runner present means the instance registered before the restart. Registering again
        // would replace it, so a partly registered set (several runners, some missing) is watched too.
        let busy = runners.contains { $0.busy }
        var watched = record
        watched.phase = busy ? .busy : .ready
        let phase = watched.phase
        updateRecord(id) { $0.phase = phase }
        Log.info(id, "runner already registered on \(forge.name) (\(busy ? "busy" : "idle")): watching it, not registering")
        resumeLifecycle(for: watched)
    }

    /// Holds a recovered instance with no lifecycle task until its forge can answer. Nothing
    /// registers it meanwhile; `settleAdoptions` retries it each reconcile pass, and the status
    /// shows it as an alert so a held instance is never mistaken for an empty fleet.
    func holdAdoption(_ id: String, reason: String) async {
        pendingAdoptions.withLock { _ = $0.insert(id) }
        Log.warn(id, "holding recovered instance: \(reason); it is not registered until the forge answers")
        await publishAdoptionAlert()
    }

    /// Retries every held instance. Runs at the start of each reconcile pass, before the scale plan
    /// reads the records, and does nothing (no forge calls) when nothing is held.
    func settleAdoptions() async {
        let held = pendingAdoptions.withLock { $0 }
        guard !held.isEmpty else { return }
        for id in held.sorted() {
            guard let record = store.all.first(where: { $0.id == id }) else {
                // Gone (the unwatched sweep or a delete removed it): nothing left to hold.
                pendingAdoptions.withLock { _ = $0.remove(id) }
                continue
            }
            await resumeAdopted(record)
        }
        await publishAdoptionAlert()
    }

    /// Shows the held instances as one alert, cleared once none are held.
    func publishAdoptionAlert() async {
        let held = pendingAdoptions.withLock { $0.sorted() }
        let message =
            held.isEmpty
            ? nil
            : "holding \(held.count) recovered instance(s) until their forge answers, not registering them: "
                + held.joined(separator: ", ")
        await statusBox.modify { $0.setAlert("adoption", message) }
    }
}
