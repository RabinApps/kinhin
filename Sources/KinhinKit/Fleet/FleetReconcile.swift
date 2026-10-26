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
        await surfaceCorruptStateFiles()
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
            } catch is CancellationError {
                return  // stopping: the next start recovers
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
                guard InstanceNaming.isOurs(name) else { continue }
                // A scratch VM an image bake left behind is not a runner: adopting it would register it on a forge.
                guard !name.hasPrefix(ImagePreparer.scratchPrefix) else { continue }
                // A benchmark's instances are not runners: adopting one would register it on a forge.
                guard !name.hasPrefix(BenchmarkNaming.instancePrefix) else { continue }
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
                // A warm instance may have been stopped with the host: re-run boot to check it (it
                // returns to `warm` through the pooled flag).
                if r.phase == .warm { r.phase = .booting }
                // Records from builds that did not store a runtime.
                if r.runtime == nil { r.runtime = owner.rawValue }
                kept.append(r)
            } else if unlisted.contains(record.runtimeID ?? .tart) {
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

        // Adopted/booted instances re-enter lifecycle through the forge's word on their runner (see
        // `resumeAdopted`); those mid-delete get cleaned. Each forge is asked once for the whole set.
        let listings = await adoptionListings(for: kept)
        for record in kept {
            if record.phase == .deleting {
                await deleteVMRecord(id: record.id, reason: "cleanup after restart")
            } else {
                await resumeAdopted(record, listings: listings)
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
                await sweepOrphansIfDue()
                await statusBox.modify { $0.setAlert("reconcile", nil) }
            } catch is CancellationError {
                return  // engine stopping: the loop exits instead of logging a cancel as an error
            } catch {
                let message = (error as? LocalizedError)?.errorDescription ?? "\(error)"
                Log.error("engine", "reconcile failed: \(message)")
                await statusBox.modify { $0.setAlert("reconcile", message) }
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

        // Forges that failed at startup get another chance (backed off), in the background: an
        // attach talks to the forge and must not hold the pass up.
        startForgeRetryIfDue()
        // Held recovered instances get another look before the plan counts them.
        await settleAdoptions()

        // 1. Clean up finished/failed VMs. Each teardown runs as its own task (one per instance), so
        // the pass moves on to the queue at once; the failure is counted only by the pass that starts
        // the delete, never again while it runs.
        for record in store.all where record.phase == .failed {
            if scheduleDelete(id: record.id, reason: "failed: \(record.error ?? "unknown")") {
                noteSpawnFailure(record)
            }
        }

        // A teardown that failed leaves its record in `.deleting`: try again.
        for record in store.all where record.phase == .deleting {
            scheduleDelete(id: record.id, reason: "retrying failed teardown")
        }

        // 2. Ask each attached forge for demand and running-work attribution.
        let attached = forgeState.withLock { Array($0.byPlatform.values) }
        let demand = try await pollDemand(attached, paused: state.paused)

        // 3. Decide the whole pass once (spawns, scale-down) and publish it.
        let plan = scalePlan(demand: demand, attached: attached)
        await publishDesired(plan.desired)
        // A paused pass masks the queue (see `pollDemand`), so it never
        // counts as idle.
        let outcome = PassOutcome(idle: !state.paused && demand.queueDepth == 0 && plan.active == 0)
        guard !state.paused else { return outcome }

        // 4. Spawn the planned instances, then 5. scale idle surplus down.
        await spawn(plan: plan, demand: demand)
        await scaleDown(plan: plan, demand: demand)
        return outcome
    }

    /// What the forges are asking for this pass.
    struct Demand {
        var queueDepth = 0
        /// Queued jobs per account (the spawn loop assigns VMs by unmet demand).
        var byForge: [String: Int] = [:]
        /// The same jobs bucketed into label pools (one per runtime).
        var byPool: [RuntimeID: Int] = [:]
        /// The same jobs per account and pool, for the scale plan.
        var byForgePool: [String: [RuntimeID: Int]] = [:]
        /// Accounts whose queue counts running jobs too (`Forge.queueIncludesRunning`).
        var includesRunning: Set<String> = []
        /// Queued tart jobs served by a ready derived per-project image.
        var byImage: [String: Int] = [:]
        /// Jobs waiting on an image bake, for the status snapshot.
        var imageNotices: Set<String> = []
        /// Accounts whose queue could not be read this pass. A failed read is
        /// not "no jobs": while any forge is unreadable the demand is
        /// incomplete, so the pass must not scale idle instances down on it.
        var failedForges: Set<String> = []
    }

    /// Polls every attached forge's queue (and running work) into `Demand`
    /// and the status snapshot. Paused without auto-resume, nothing is
    /// polled and attribution is cleared. Paused with auto-resume, the queue
    /// is still watched — the pause releases the moment demand drains — but
    /// no demand is returned, so nothing spawns this pass.
    func pollDemand(_ attached: [Forge], paused: Bool) async throws -> Demand {
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
        // One routing snapshot for the whole pass: a reload landing mid-pass applies from the next one.
        let routerState = router.snapshot
        let ordered = attached.sorted { $0.account < $1.account }
        // `try`, not `try?`: cancellation must propagate, not read as "no answers".
        let answers =
            try await boundedMap(ordered, limit: 4) { forge -> ForgeAnswer in
                do {
                    let jobs = try await forge.queuedJobs()
                    let images = await self.resolveProjectImages(for: jobs, forge: forge, routerState: routerState)
                    return .answered(jobs: jobs, images: images)
                } catch is CancellationError {
                    // A cancelled pass is not a failed forge: no queue alert.
                    throw CancellationError()
                } catch {
                    return .failed(message: (error as? LocalizedError)?.errorDescription ?? "\(error)")
                }
            }
        for (forge, answer) in zip(ordered, answers) {
            switch answer {
            case .answered(let jobs, let projectDemand):
                answeredQueue = true
                await statusBox.modify { $0.setAlert("queue:\(forge.account)", nil) }
                // Org-scope forges contribute repo attribution; repo-scope
                // forges suppress it (breakdown would carry no info).
                perForgeJobs[forge.account] = (forge.attributesByRepo, jobs)
                demand.byForge[forge.account] = jobs.count
                demand.queueDepth += jobs.count
                let pools = routerState.model.demandByPool(for: jobs, forgeID: forge.id)
                demand.byForgePool[forge.account] = pools
                if forge.queueIncludesRunning { demand.includesRunning.insert(forge.account) }
                for (poolID, count) in pools {
                    demand.byPool[poolID, default: 0] += count
                }
                for (image, count) in projectDemand.byImage { demand.byImage[image, default: 0] += count }
                demand.imageNotices.formUnion(projectDemand.notices)
            case .failed(let message):
                Log.warn("engine", "could not fetch \(forge.name) queue: \(message)")
                demand.failedForges.insert(forge.account)
                await statusBox.modify { $0.setAlert("queue:\(forge.account)", message) }
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
            // Jobs keep running on the VMs while the pause holds back new ones: keep Current jobs live.
            await attributeRunningJobs(attached)
            return Demand()
        }
        let byRepo = ForgeDemand.mergeQueueByRepo(perForgeJobs)
        // When no forge answered, keep the last observed queue: publishing 0
        // would show a healthy empty queue during an outage.
        let nothingAnswered = !ordered.isEmpty && !answeredQueue
        await statusBox.modify { [demand] in
            $0.imageNotice = demand.imageNotices.isEmpty ? nil : demand.imageNotices.sorted().joined(separator: "; ")
            if !nothingAnswered {
                $0.queueDepth = demand.queueDepth
                $0.queueByRepo = byRepo
            }
            if answeredQueue { $0.queuePolledAt = Date() }
        }
        await attributeRunningJobs(attached)
        return demand
    }

    /// The pure scaling decision for this pass, from the records, the forges'
    /// demand, the caps and the spawn backoff.
    func scalePlan(demand: Demand, attached: [Forge]) -> ScalePlan {
        let held = spawnBackoff.withLock { $0.blocked(now: Date()) }
        let routerState = router.snapshot
        let routing = routerState.model
        return ScalePlan.make(
            ScalePlan.Input(
                records: store.all, demand: demand.byForgePool, includesRunning: demand.includesRunning,
                attached: Set(attached.map(\.account)), failedForges: demand.failedForges,
                runnersPerVM: max(1, config.runnersPerVM), minRunners: config.minRunners,
                maxRunners: config.maxRunners, capacityCap: capacity.maxConcurrent, poolCaps: routerState.caps,
                heldRuntimes: held, existingPools: Set(routing.pools.keys), defaultRuntime: routing.defaultRuntime,
                warmPool: warmTargets(images: routerState.images),
                warmMaxAge: TimeInterval(config.warmMaxAgeMinutes) * 60, imageDemand: demand.byImage))
    }

    /// Warm instances to keep per Tart image: the base `warm_pool` ("") and each `images:` entry's own.
    func warmTargets(images: [KinhinConfig.ImageConfig]) -> [String: Int] {
        var targets: [String: Int] = [:]
        if config.warmPool > 0 { targets[""] = config.warmPool }
        for image in images where image.warmPool > 0 { targets[image.name] = image.warmPool }
        return targets
    }

    /// Publishes the desired count with the caps and records into the status snapshot.
    func publishDesired(_ desired: Int) async {
        let runnersPerVM = max(1, config.runnersPerVM)
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
    }

    /// Starts the planned instances — but never past what the disk can
    /// hold. The host is probed once per pass (a `statfs` per spawn added up
    /// in a burst); each planned instance then subtracts its own disk share.
    /// Host-runtime slots cost no disk, so they skip it.
    func spawn(plan: ScalePlan, demand: Demand) async {
        defer { publishSpawnBackoff() }
        var slots = plan.slots
        var diskPressureMessage: String?
        if slots.contains(where: { $0.runtime != .host && $0.claim == nil }) {
            let listed = slots.contains { $0.image != nil } ? await listedTartVMs() : []
            let admission = ScalePlan.admitByDisk(
                slots, freeDiskGB: hostProbe().freeDiskGB, reserveGB: config.reserve.diskGB,
                diskPerInstanceGB: { diskPerInstanceGB($0, listed: listed) })
            slots = admission.admitted
            if let blocked = admission.blocked {
                diskPressureMessage =
                    "disk pressure: \(blocked.availableGB) GB free, a new \(blocked.runtime.rawValue) instance needs \(blocked.neededGB - config.reserve.diskGB) GB + \(config.reserve.diskGB) GB reserve — holding spawns"
            }
        }
        if !slots.isEmpty, spawnBackoff.withLock({ $0.blocked(now: Date()) }).isEmpty {
            Log.info("engine", "scaling up: \(plan.active) active, want \(plan.target) (queue \(demand.queueDepth))")
        }
        for id in plan.evict { scheduleDelete(id: id, reason: "warm instance evicted") }
        for slot in slots {
            // A claimed warm instance is bound to its slot; it is already on disk, so disk pressure never holds it.
            if let warmID = slot.claim {
                claimWarm(id: warmID, account: slot.account)
                continue
            }
            var record = VMRecord(id: VMRecord.newName(), phase: .cloning)
            record.platform = slot.account
            record.runtime = slot.runtime.rawValue
            record.image = slot.image
            store.upsert(record)
            // The lifecycle waits its turn at the engine's `SpawnPacer`, so disk I/O does not
            // stampede; the pass itself never sleeps.
            spawnLifecycle(for: record)
        }
        await topUpWarmPool(plan.warmSpawn, diskBlocked: diskPressureMessage != nil)
        if let diskPressureMessage {
            Log.warn("engine", diskPressureMessage)
            await statusBox.modify { status in
                status.setAlert("disk", diskPressureMessage)
                status.diskPressureNotice = diskPressureMessage
            }
        } else {
            // Spawns resumed: clear a stale disk-pressure message (other
            // errors belong to their own flows).
            await statusBox.modify { status in
                status.setAlert("disk", nil)
                status.diskPressureNotice = nil
            }
        }
    }

    /// What the engine last learned from `tart list` (see `FleetEngine.tartListing`).
    struct TartListing: Sendable {
        var vms: [TartVM] = []
        var fetchedAt: Date?
        /// Named images whose warm pool was skipped as unprepared, so each skip is logged once.
        var skipped: Set<String> = []
    }

    /// How long one `tart list` answer serves the reconcile passes that ask for it.
    static let tartListingMaxAge: TimeInterval = 60

    /// The Tart VMs on this Mac, with their disk sizes, reused for `tartListingMaxAge`. A failed
    /// `tart list` is not cached and returns none, so a named image is then treated as not prepared
    /// (its warm pool is skipped) rather than guessed at.
    func listedTartVMs() async -> [TartVM] {
        let fresh = tartListing.withLock { state -> [TartVM]? in
            guard let at = state.fetchedAt, Date().timeIntervalSince(at) < Self.tartListingMaxAge else { return nil }
            return state.vms
        }
        if let fresh { return fresh }
        let vms: [TartVM]
        do {
            vms = try await tart.list()
        } catch {
            // Not cached, and none means "not prepared" (the conservative answer); a
            // cancelled pass discards it. Anything else is logged, not hidden.
            if !(error is CancellationError) {
                Log.warn("reconcile", "tart list failed: \(error.localizedDescription)")
            }
            return []
        }
        tartListing.withLock { state in
            state.vms = vms
            state.fetchedAt = Date()
        }
        return vms
    }

    /// Disk a new instance of `slot` takes. A Tart clone of a named image costs that image's own disk
    /// size, as `tart list` reports it; the base image, other runtimes, and an unknown size use the
    /// configured VM disk.
    func diskPerInstanceGB(_ slot: ScalePlan.Slot, listed: [TartVM]) -> Int {
        guard slot.runtime == .tart else {
            return ResourceProbe.effectiveDiskPerVMGB(diskGB: config.diskGB, runtime: slot.runtime)
        }
        let size = slot.image.flatMap { name in listed.first { $0.name == name }?.diskGB }
        return ResourceProbe.effectiveDiskPerVMGB(diskGB: size ?? config.diskGB, runtime: .tart)
    }

    /// Starts the warm instances planned per image (cloned and booted, never registered) unless the
    /// disk is short. A named image that is not prepared yet has nothing to clone, so it is skipped.
    func topUpWarmPool(_ spawns: [String: Int], diskBlocked: Bool) async {
        guard !spawns.isEmpty, !diskBlocked else { return }
        var wanted = spawns
        var listed: [TartVM] = []
        let named = spawns.keys.filter { !$0.isEmpty }
        if !named.isEmpty {
            listed = await listedTartVMs()
            let prepared = Set(listed.map(\.name))
            let missing = Set(named.filter { !prepared.contains($0) })
            for image in missing { wanted[image] = nil }
            // An image that is prepared again is forgotten, so a later skip is logged again.
            let newlySkipped = tartListing.withLock { state -> [String] in
                state.skipped.formIntersection(missing)
                let fresh = missing.subtracting(state.skipped)
                state.skipped.formUnion(missing)
                return fresh.sorted()
            }
            for image in newlySkipped {
                Log.warn("engine", "warm pool for image \(image) skipped: it is not prepared")
            }
        }
        var planned: [ScalePlan.Slot] = []
        for image in wanted.keys.sorted() {
            let slot = ScalePlan.Slot(account: "", runtime: .tart, image: image.isEmpty ? nil : image)
            planned += Array(repeating: slot, count: wanted[image] ?? 0)
        }
        guard !planned.isEmpty else { return }
        let free = hostProbe().freeDiskGB
        let slots = ScalePlan.admitByDisk(
            planned, freeDiskGB: free, reserveGB: config.reserve.diskGB,
            diskPerInstanceGB: { diskPerInstanceGB($0, listed: listed) }
        ).admitted
        for slot in slots {
            var record = VMRecord(id: VMRecord.newName(), phase: .cloning)
            record.runtime = RuntimeID.tart.rawValue
            record.image = slot.image
            record.pooled = true
            store.upsert(record)
            Log.info(record.id, "starting warm instance\(slot.image.map { " for \($0)" } ?? "")")
            spawnLifecycle(for: record)
        }
    }

    /// A failed instance counts against its runtime's spawn backoff.
    func noteSpawnFailure(_ record: VMRecord) {
        guard let runtime = record.runtimeID else { return }
        noteSpawnFailure(runtime: runtime, reason: record.error ?? "unknown")
    }

    /// Counts a failed start against `runtime`'s spawn backoff.
    func noteSpawnFailure(runtime: RuntimeID, reason: String) {
        let delay = spawnBackoff.withLock { $0.recordFailure(runtime, reason: reason, now: Date()) }
        if delay > 0 {
            Log.warn(
                "engine",
                "\(runtime.rawValue) runners failed to start repeatedly; holding new ones for \(Int(delay))s — \(reason)"
            )
        }
    }

    /// Shows the backoff in the status line while it holds spawns, and clears
    /// only its own message once spawns are free again.
    func publishSpawnBackoff() {
        let summary = spawnBackoff.withLock { $0.summary(now: Date()) }
        Task { [statusBox] in
            await statusBox.modify { status in
                status.setAlert("spawn-backoff", summary)
            }
        }
    }

    /// Deletes the plan's idle surplus — never from a pool whose jobs are
    /// still waiting, and not at all while a forge's queue is unreadable.
    func scaleDown(plan: ScalePlan, demand: Demand) async {
        // An unreadable queue is not an empty one: keep idle (and warm)
        // instances until every forge answers again.
        if plan.scaleDownHeld {
            let accounts = demand.failedForges.sorted().joined(separator: ", ")
            Log.warn("engine", "holding scale-down: could not read the queue of \(accounts)")
            return
        }
        for id in plan.scaleDown {
            guard await confirmIdleForScaleDown(id) else { continue }
            Log.info("engine", "scaling down: deleting idle \(id)")
            scheduleDelete(id: id, reason: "scale down")
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
