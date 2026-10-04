import Foundation
import Yams

// FleetEngine — reconcile loop, recovery, and running-job attribution.
extension FleetEngine {
    // MARK: - Recovery

    /// After a crash or restart: figure out which fleet instances still
    /// exist (containers or Tart VMs), rebuild records, and clean up
    /// anything orphaned.
    func recoverIfNeeded() async {
        Log.info("engine", "reconciling existing instances after (re)start")
        // Enumerate every configured runtime through the protocol — the map
        // (not per-runtime branches) is the source of truth.
        // Remember which runtime reported each instance: an adopted or
        // legacy record must be driven through the runtime that owns it,
        // not the engine's primary one (mixed fleets).
        var ownerByName: [String: RuntimeID] = [:]
        var ours: [String] = []
        // Runtimes that couldn't be asked: their records are kept as they
        // are (a failed listing is not proof the instances are gone).
        var unlisted: Set<RuntimeID> = []
        for (runtimeID, runtimeInstance) in runtimesByRuntime.sorted(by: { $0.key.rawValue < $1.key.rawValue }) {
            let names: [String]
            do {
                names = try await runtimeInstance.existingInstanceIDs()
            } catch {
                Log.warn(
                    "engine",
                    "could not list \(runtimeID.rawValue) instances (\(error.localizedDescription)); keeping their records"
                )
                unlisted.insert(runtimeID)
                continue
            }
            for name in names {
                // "Ours" = instances this build spawns ("kinhin-") plus ones the
                // pre-rename build spawned ("orchard-") so in-flight VMs are still
                // recovered, attributed, and cleaned up across the rename.
                guard name.hasPrefix("kinhin-") || name.hasPrefix("orchard-") else { continue }
                if ownerByName[name] == nil {
                    ownerByName[name] = runtimeID
                    ours.append(name)
                }
            }
        }
        let records = store.all

        // Records whose instance vanished (deleted out-of-band) get dropped.
        var kept: [VMRecord] = []
        for record in records where record.phase.isActive {
            if let owner = ownerByName[record.id] {
                var r = record
                // Rebooting engine: restart lifecycle from "booting" if the
                // instance still exists.
                if r.phase == .cloning {
                    r.phase = .booting
                }
                // Records from builds that did not store a runtime.
                if r.runtime == nil { r.runtime = owner.rawValue }
                kept.append(r)
            } else if unlisted.contains(RuntimeID(rawValue: record.runtime ?? "") ?? .tart) {
                kept.append(record)
            } else {
                Log.warn("engine", "record for \(record.id) has no matching instance; dropping")
            }
        }

        // Instances of ours with no record: adopt them, then decide below.
        for name in ours where !kept.contains(where: { $0.id == name }) {
            guard let owner = ownerByName[name] else { continue }
            Log.info("engine", "adopting existing instance \(name) (\(owner.rawValue))")
            var adopted = VMRecord(id: name, phase: .booting, createdAt: Date())
            adopted.runtime = owner.rawValue
            kept.append(adopted)
        }

        store.replaceAll(kept)

        // Adopted/booted instances re-enter lifecycle; those mid-delete get cleaned.
        for record in kept {
            if record.phase == .deleting {
                await deleteVMRecord(id: record.id, reason: "cleanup after restart")
            } else {
                spawnLifecycle(for: record)
            }
        }
    }

    // MARK: - Reconcile loop

    func reconcileLoop() async {
        var cadence = PollCadence()
        var slowdown: PollCadence.Slowdown?
        while !Task.isCancelled {
            var idle = false
            do {
                idle = try await reconcileOnce().idle
            } catch is CancellationError {
                return  // engine stopping: the loop exits instead of logging a cancel as an error
            } catch {
                let message = (error as? LocalizedError)?.errorDescription ?? "\(error)"
                Log.error("engine", "reconcile failed: \(message)")
                await statusBox.modify { $0.lastError = message }
            }
            let paused = runState.withLock { $0.paused }
            let attached = forgeState.withLock { Array($0.byPlatform.values) }
            let tightestBudget = PollCadence.tightest(attached.compactMap(\.rateLimit))
            let next = cadence.next(
                base: config.pollInterval, idle: idle, paused: paused, budget: tightestBudget)
            if next.slowdown != slowdown {
                Log.info(
                    "engine",
                    next.slowdown.map { "polling every \(next.seconds)s (\($0.rawValue))" }
                        ?? "polling every \(next.seconds)s")
                slowdown = next.slowdown
            }
            await statusBox.modify {
                $0.currentPollInterval = next.seconds
                $0.pollSlowdown = next.slowdown?.rawValue
                $0.rateLimitResetAt = next.slowdown == nil ? nil : tightestBudget?.resetAt
            }
            do {
                try await waitForNextPass(seconds: next.seconds)
            } catch {
                return  // cancellation ends the loop
            }
        }
    }

    /// Sleeps until the next pass is due, or until something asked for one
    /// now (`pollSoon()`: a resume or config reload must not sit out an
    /// idle backoff).
    func waitForNextPass(seconds: Int) async throws {
        let deadline = ContinuousClock.now + .seconds(seconds)
        while true {
            let requested = runState.withLock { state in
                defer { state.pollNow = false }
                return state.pollNow
            }
            if requested || ContinuousClock.now >= deadline { return }
            // One sleep to the deadline, cut short by `pollSoon()`'s signal:
            // no periodic polling of the flag. A stale signal (its flag
            // already consumed above) just loops once more.
            try await pollWake.sleep(until: deadline)
        }
    }

    /// Cuts the current wait short: the loop runs its next pass now.
    func pollSoon() {
        runState.withLock { $0.pollNow = true }
        pollWake.signal()
    }

    /// What a pass saw, for the loop's cadence.
    struct PassOutcome {
        /// Running, nothing queued and no instances: nothing to react to.
        var idle: Bool
    }

    /// One pass of the control loop. Public for tests.
    @discardableResult
    func reconcileOnce() async throws -> PassOutcome {
        let state = runState.withLock { $0 }

        // Forges that failed at startup get another chance (backed off).
        await retryDetachedForgesIfDue()

        // 1. Clean up finished/failed VMs.
        for record in store.all where record.phase == .failed {
            await deleteVMRecord(id: record.id, reason: "failed: \(record.error ?? "unknown")")
        }

        // 2. Ask each attached forge for demand and running-work attribution.
        let attached = forgeState.withLock { Array($0.byPlatform.values) }
        let demand = await pollDemand(attached, paused: state.paused)

        // 3. Decide the desired count and publish it.
        let desired = await publishDesired(queueDepth: demand.queueDepth)
        let active = store.all.filter { $0.phase.isActive }.count
        // A paused pass masks the queue (see `pollDemand`), so it never
        // counts as idle.
        let outcome = PassOutcome(idle: !state.paused && demand.queueDepth == 0 && active == 0)
        guard !state.paused else { return outcome }

        // 4. Spawn up to desired, then 5. scale idle surplus down.
        try await spawn(upTo: desired, active: active, demand: demand, attached: attached)
        await scaleDown(active: active, desired: desired, demand: demand)
        return outcome
    }

    /// What the forges are asking for this pass.
    struct Demand {
        var queueDepth = 0
        /// Queued jobs per account (the spawn loop assigns VMs by unmet demand).
        var byForge: [String: Int] = [:]
        /// The same jobs bucketed into label pools (one per runtime).
        var byPool: [RuntimeID: Int] = [:]
        /// Queued tart jobs served by a ready derived per-project image.
        var byImage: [String: Int] = [:]
        /// Jobs waiting on an image bake, for the status snapshot.
        var imageNotices: Set<String> = []
    }

    /// Polls every attached forge's queue (and running work) into `Demand`
    /// and the status snapshot. Paused without auto-resume, nothing is
    /// polled and attribution is cleared. Paused with auto-resume, the queue
    /// is still watched — the pause releases the moment demand drains — but
    /// no demand is returned, so nothing spawns this pass.
    func pollDemand(_ attached: [Forge], paused: Bool) async -> Demand {
        guard !paused || config.autoResume else {
            // Clear attribution so stale repos don't linger.
            await statusBox.modify { $0.runningByRepo = nil }
            await clearRunningAttribution()
            return Demand()
        }
        var demand = Demand()
        var perForgeJobs: [String: (attribution: Bool, jobs: [ForgeJob])] = [:]
        var answeredQueue = false
        // Every forge's queue (and its project-image resolution) is read
        // concurrently, bounded; the results are folded in account order so
        // the demand is deterministic whatever finishes first.
        enum ForgeAnswer: Sendable {
            case answered(jobs: [ForgeJob], images: ProjectImageDemand)
            case failed(message: String)
        }
        let ordered = attached.sorted { $0.account < $1.account }
        let answers =
            (try? await boundedMap(ordered, limit: 4) { forge -> ForgeAnswer in
                do {
                    let jobs = try await forge.queuedJobs()
                    let images = await self.resolveProjectImages(for: jobs, forge: forge)
                    return .answered(jobs: jobs, images: images)
                } catch {
                    return .failed(message: (error as? LocalizedError)?.errorDescription ?? "\(error)")
                }
            }) ?? []
        for (forge, answer) in zip(ordered, answers) {
            switch answer {
            case .answered(let jobs, let projectDemand):
                answeredQueue = true
                // Org-scope forges contribute repo attribution; repo-scope
                // forges suppress it (breakdown would carry no info).
                perForgeJobs[forge.account] = (forge.attributesByRepo, jobs)
                demand.byForge[forge.account] = jobs.count
                demand.queueDepth += jobs.count
                for (poolID, count) in routing.demandByPool(for: jobs, forgeID: forge.id) {
                    demand.byPool[poolID, default: 0] += count
                }
                for (image, count) in projectDemand.byImage { demand.byImage[image, default: 0] += count }
                demand.imageNotices.formUnion(projectDemand.notices)
            case .failed(let message):
                Log.warn("engine", "could not fetch \(forge.name) queue: \(message)")
                await statusBox.modify { $0.lastError = message }
            }
        }
        if paused {
            // Paused with auto-resume: hold while demand remains, release once
            // the queue is empty. A forge outage (every fetch failed) must NOT
            // read as "nothing to do" and unpause over the user's head.
            if demand.queueDepth == 0, !demand.byForge.isEmpty {
                Log.info("engine", "auto-resume: queue is empty while paused")
                runState.withLock { $0.paused = false }
            }
            // The snapshot keeps queueDepth 0 while paused, but the
            // observation was real: stamp its freshness. An outage leaves
            // the old timestamp, so the age truthfully shows staleness.
            if answeredQueue { await statusBox.modify { $0.queuePolledAt = Date() } }
            return Demand()
        }
        let byRepo = ForgeDemand.mergeQueueByRepo(perForgeJobs)
        await statusBox.modify { [demand] in
            $0.imageNotice = demand.imageNotices.isEmpty ? nil : demand.imageNotices.sorted().joined(separator: "; ")
            $0.queueDepth = demand.queueDepth
            $0.queueByRepo = byRepo
            if answeredQueue { $0.queuePolledAt = Date() }
        }
        await attributeRunningJobs(attached)
        return demand
    }

    /// The desired instance count for `queueDepth`, published with the caps
    /// and records into the status snapshot.
    func publishDesired(queueDepth: Int) async -> Int {
        let runnersPerVM = max(1, config.runnersPerVM)
        let desired = Autoscaler.desiredCount(
            queueDepth: queueDepth, minRunners: config.minRunners, maxRunners: config.maxRunners,
            capacityCap: capacity.maxConcurrent, runnersPerVM: runnersPerVM)
        let jobCapacity = Autoscaler.jobCapacity(
            maxRunners: config.maxRunners, capacityCap: capacity.maxConcurrent, runnersPerVM: runnersPerVM)
        let records = store.all
        await statusBox.modify { [capacity] in
            $0.desired = desired
            $0.capacityCap = capacity.maxConcurrent
            $0.jobCapacity = jobCapacity
            $0.records = records
            $0.updatedAt = Date()
        }
        return desired
    }

    /// Starts instances up to `desired` — but never past what the disk can
    /// hold. The plan-time cap uses the last probed free space; this
    /// re-probe catches queue bursts that would otherwise fill the disk
    /// between spawns. Host-runtime slots cost no disk, so they skip it.
    func spawn(upTo desired: Int, active: Int, demand: Demand, attached: [Forge]) async throws {
        var toSpawn = desired - active
        if toSpawn > 0 {
            Log.info("engine", "scaling up: \(active) active, want \(desired) (queue \(demand.queueDepth))")
        }
        var diskPressureMessage: String?
        // The host is probed once per pass (a `statfs` per spawn added up in
        // a burst); each planned instance then subtracts its own disk share.
        var freeDisk: Int?
        while toSpawn > 0 {
            var record = VMRecord(id: VMRecord.newName(), phase: .cloning)
            // The forge with the most unmet demand (its queued jobs minus VMs
            // already serving it). Only attached forges are candidates, and a
            // forge only attaches with a working token.
            record.platform = ForgeDemand.assignAccount(
                demand: demand.byForge, active: activeByPlatform(), attached: Set(attached.map(\.account)))
            // The label pool with the most unmet demand, within its capacity
            // partition. Single-pool fleets reduce to the primary runtime.
            let chosen = selectRuntime(
                demand: demand.byPool, active: activeByRuntime(), caps: capsByRuntime, fallback: routing.defaultRuntime)
            record.runtime = chosen.rawValue
            if chosen == .tart { record.image = chooseImage(demand: demand) }
            if chosen != .host {
                let diskPerVM = ResourceProbe.effectiveDiskPerVMGB(diskGB: config.diskGB, runtime: chosen.rawValue)
                let available = freeDisk ?? hostProbe().freeDiskGB
                let needed = diskPerVM + config.reserve.diskGB
                if available < needed {
                    diskPressureMessage =
                        "disk pressure: \(available) GB free, a new \(chosen.rawValue) instance needs \(diskPerVM) GB + \(config.reserve.diskGB) GB reserve — holding spawns"
                    break
                }
                freeDisk = available - diskPerVM
            }
            store.upsert(record)
            spawnLifecycle(for: record)
            toSpawn -= 1
            // Stagger spawns slightly so disk I/O doesn't stampede (nothing to
            // stagger after the last one). Cancellation stops further
            // staggering (already-spawned VMs keep winding down).
            if toSpawn > 0 { try await Task.sleep(for: spawnStagger) }
        }
        if let diskPressureMessage {
            Log.warn("engine", diskPressureMessage)
            await statusBox.modify { status in
                status.lastError = diskPressureMessage
                status.diskPressureNotice = diskPressureMessage
            }
        } else {
            // Spawns resumed: clear a stale disk-pressure message (other
            // errors belong to their own flows).
            await statusBox.modify { status in
                if status.lastError?.contains("disk pressure") == true { status.lastError = nil }
                status.diskPressureNotice = nil
            }
        }
    }

    /// Deletes idle instances beyond `desired` — never from a pool whose
    /// jobs are still waiting.
    func scaleDown(active: Int, desired: Int, demand: Demand) async {
        guard active > desired else { return }
        let idle = store.all.filter { $0.phase == .ready }.sorted { $0.createdAt < $1.createdAt }
        var surplus = active - desired
        for record in idle where surplus > 0 {
            let poolID = RuntimeID(rawValue: record.runtime ?? "") ?? routing.defaultRuntime
            let unmet = (demand.byPool[poolID] ?? 0) - (activeByRuntime()[poolID] ?? 0)
            guard unmet <= 0 else { continue }  // this pool still needs capacity
            Log.info("engine", "scaling down: deleting idle \(record.id)")
            await deleteVMRecord(id: record.id, reason: "scale down")
            surplus -= 1
        }
    }

    // MARK: - Running-job attribution

    /// Stamp each VM with the repos of the jobs its runners are currently
    /// executing (attribution where the forge exposes it). Runner names are
    /// VM ids, so one pass stamps each VM whichever account it serves. Every
    /// attached forge contributes: GitHub carries repo attribution per job;
    /// Gitea (and Forgejo) attribute busy runners per VM. A failed forge is
    /// skipped, but if none answered the stamps are left as they were.
    func attributeRunningJobs(_ attached: [Forge]) async {
        var runningAll: [RunningJob] = []
        var answered = false
        // Attribution is cosmetic: a forge low on API budget keeps it for
        // demand reads, which scaling depends on.
        for forge in attached where forge.rateLimit?.isLow != true {
            do {
                let running = try await forge.runningJobs()
                answered = true
                runningAll.append(
                    contentsOf: running.map {
                        RunningJob(name: $0.name, runnerName: $0.runnerName, repository: $0.repository)
                    })
            } catch {
                // Attribution is best-effort telemetry: never fail reconcile
                // over it (the queued-fetch handler above already logged).
                Log.warn("engine", "could not fetch \(forge.name) running jobs: \(error)")
            }
        }
        if answered { await applyRunningAttribution(runningAll) }
    }
}
