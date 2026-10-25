import Foundation

// MARK: - Adoption (restart recovery)

/// What one forge answered in a recovery or settle pass. It is read once per account, so every instance that
/// account holds shares one request.
struct AdoptionListing: Sendable {
    /// The forge's runner list.
    var runners: [ForgeRunner]
    /// Jobs running in the scope when the forge has no runner list (see `Forge.unlistedRunnerActivity`);
    /// nil when it has one.
    var unlistedRunning: Int?
}

extension FleetEngine {
    /// Whether a recovered record must be checked against its forge before anything runs on it. Instances the engine
    /// already drove, and pooled warm VMs (which never register), keep their phase-based path.
    static func needsForgeCheck(_ record: VMRecord) -> Bool {
        record.phase != .ready && record.phase != .busy && record.pooled != true
    }

    /// `needsForgeCheck`, plus the one registered case it cannot cover alone: an idle classic runner in a Linux
    /// container. Its agent is a background process of the container, so a restart that stopped the container (host
    /// reboot, `container system stop`) kills it, and `container start` brings back only the idle shell. Nothing
    /// watches a classic runner after registration (`resumeLifecycle`), so the record would read `ready` forever
    /// with no runner on the forge. Such a record is checked like an unregistered one. Ephemeral and scale-set
    /// runners are left out: their exit watch already deletes an instance whose runner is gone, and registering
    /// again would reuse a container that may have run its one job.
    func checksForgeOnRecovery(_ record: VMRecord) -> Bool {
        if Self.needsForgeCheck(record) { return true }
        guard record.phase == .ready, record.runtimeID == .appleContainer || record.runtimeID == .docker,
            let forge = forgeState.withLock({ $0.byPlatform[record.platform ?? ForgeID.github.rawValue] })
        else { return false }
        return !watchesRunnerExit(on: forge)
    }

    /// Reads each attached forge that holds a recovered instance, once. An account whose forge fails to answer has no
    /// entry, so its instances are held rather than guessed at.
    func adoptionListings(for records: [VMRecord]) async -> [String: AdoptionListing] {
        var listings: [String: AdoptionListing] = [:]
        let accounts = Set(records.filter(checksForgeOnRecovery).map { $0.platform ?? ForgeID.github.rawValue })
        for account in accounts.sorted() {
            guard let forge = forgeState.withLock({ $0.byPlatform[account] }) else { continue }
            do {
                // Fresh: a stale list could miss a runner registered just before the restart. The list comes first:
                // a forge with no list only reports its activity once the list has been asked for.
                let runners = try await runnerDirectory.freshRunners(of: forge)
                let unlisted = try await forge.unlistedRunnerActivity(fresh: true)
                listings[account] = AdoptionListing(runners: runners, unlistedRunning: unlisted)
            } catch {
                Log.warn("engine", "could not read \(forge.name) runners for recovery: \(error.localizedDescription)")
            }
        }
        return listings
    }

    /// Re-enters an instance a restart found on its runtime. Registration runs only when the forge has no runner for
    /// it: registering replaces a runner by name (`config.sh --replace`) or is rejected for an existing JIT name, so
    /// replaying it on a VM that is mid-job fails that job. A runner the forge already has is watched instead, busy or
    /// idle. A forge that cannot answer holds the instance (see `holdAdoption`) rather than guess.
    func resumeAdopted(_ record: VMRecord, listings: [String: AdoptionListing]) async {
        guard checksForgeOnRecovery(record) else {
            resumeLifecycle(for: record)
            return
        }
        let id = record.id
        let account = record.platform ?? ForgeID.github.rawValue
        // An account removed from the config has no forge that will ever answer, so its VM is released as before.
        guard config.accounts.contains(where: { $0.name == account }) else {
            pendingAdoptions.withLock { _ = $0.removeValue(forKey: id) }
            await deleteVMRecord(id: id, reason: "account \(account) is no longer configured")
            return
        }
        guard let forge = forgeState.withLock({ $0.byPlatform[account] }) else {
            await holdAdoption(id, reason: "no \(account) forge attached yet")
            return
        }
        guard let listing = listings[account] else {
            await holdAdoption(id, reason: "could not read \(forge.name) runners")
            return
        }
        pendingAdoptions.withLock { _ = $0.removeValue(forKey: id) }
        let expected = Self.runnerNames(for: id, count: config.runnersPerVM)

        if let running = listing.unlistedRunning {
            // No runner list: the forge cannot say whether this VM's runner registered. With nothing running in the
            // scope, registering disrupts nothing. With a job running, watch the scope instead; the watch removes the
            // VM once the scope goes quiet.
            // A ready classic runner (`checksForgeOnRecovery`) is registered only when the forge can list its runners:
            // here nothing says it is gone, and registering a live one again would duplicate it.
            if running == 0, Self.needsForgeCheck(record) {
                Log.info(id, "no job is running on \(forge.name): registering it")
                spawnLifecycle(for: record)
            } else {
                watchAdopted(record, busy: running > 0, forgeName: forge.name)
            }
            return
        }
        let present = listing.runners.filter { expected.contains($0.name) }
        guard !present.isEmpty else {
            Log.info(id, "no runner on \(forge.name): registering it")
            spawnLifecycle(for: record)
            return
        }
        let busy = present.contains { $0.busy }
        // Some runners of the set are missing. Registering replaces by name, so it would cut off a busy one: only an
        // idle set is registered again (replacing idle runners is harmless). A busy partial set is watched. Its missing
        // runner never appears, so the VM is removed only at the watch deadline (see the docs).
        if present.count < expected.count, !busy {
            let count = "\(present.count) of \(expected.count)"
            Log.info(id, "\(count) runners on \(forge.name), none busy: registering them all")
            spawnLifecycle(for: record)
            return
        }
        watchAdopted(record, busy: busy, forgeName: forge.name)
    }

    /// Watches an instance whose runner the forge has. Nothing is registered; the phase says what the forge reported.
    func watchAdopted(_ record: VMRecord, busy: Bool, forgeName: String) {
        var watched = record
        watched.phase = busy ? .busy : .ready
        let phase = watched.phase
        updateRecord(record.id) { $0.phase = phase }
        let state = busy ? "busy" : "idle"
        Log.info(record.id, "runner already registered on \(forgeName) (\(state)): watching it, not registering")
        resumeLifecycle(for: watched)
    }

    /// Holds a recovered instance with no lifecycle task until its forge can answer. Nothing registers it meanwhile;
    /// `settleAdoptions` retries it each reconcile pass. The status shows it as an alert, so a held instance is never
    /// mistaken for an empty fleet.
    func holdAdoption(_ id: String, reason: String) async {
        pendingAdoptions.withLock { held in
            if held[id] == nil { held[id] = Date() }
        }
        Log.warn(id, "holding recovered instance: \(reason); it is not registered until the forge answers")
        await publishAdoptionAlert()
    }

    /// Retries every held instance. Runs at the start of each reconcile pass, before the scale plan reads the records,
    /// and makes no forge calls when nothing is held. An instance whose account stays unattached past
    /// `watchdog.adoptionHoldLimit` is torn down: a broken token must not hold a slot and its disk indefinitely.
    func settleAdoptions() async {
        let held = pendingAdoptions.withLock { $0 }
        guard !held.isEmpty else { return }
        let records = store.all
        let listings = await adoptionListings(for: records.filter { held[$0.id] != nil })
        for id in held.keys.sorted() {
            guard let record = records.first(where: { $0.id == id }) else {
                // Gone (the unwatched sweep or a delete removed it): nothing left to hold.
                pendingAdoptions.withLock { _ = $0.removeValue(forKey: id) }
                continue
            }
            let account = record.platform ?? ForgeID.github.rawValue
            let unattached = forgeState.withLock { $0.byPlatform[account] } == nil
            let stale = Date().timeIntervalSince(held[id] ?? Date()) >= watchdog.adoptionHoldLimit.timeInterval
            if unattached, stale {
                pendingAdoptions.withLock { _ = $0.removeValue(forKey: id) }
                let minutes = Int(watchdog.adoptionHoldLimit.timeInterval / 60)
                await deleteVMRecord(id: id, reason: "no \(account) forge attached for \(minutes) minute(s)")
                continue
            }
            await resumeAdopted(record, listings: listings)
        }
        await publishAdoptionAlert()
    }

    /// Shows the held instances as one alert, cleared once none are held.
    func publishAdoptionAlert() async {
        let held = pendingAdoptions.withLock { $0.keys.sorted() }
        let message =
            held.isEmpty
            ? nil
            : "holding \(held.count) recovered instance(s) until their forge answers, not registering them: "
                + held.joined(separator: ", ")
        await statusBox.modify { $0.setAlert("adoption", message) }
    }
}
