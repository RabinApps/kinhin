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
        for (runtimeID, runtimeInstance) in runtimesByRuntime.sorted(by: { $0.key.rawValue < $1.key.rawValue }) {
            for name in await runtimeInstance.existingInstanceIDs() {
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
        while !Task.isCancelled {
            let interval = config.pollInterval
            do {
                try await reconcileOnce()
            } catch {
                let message = (error as? LocalizedError)?.errorDescription ?? "\(error)"
                Log.error("engine", "reconcile failed: \(message)")
                await statusBox.modify { $0.lastError = message }
            }
            try? await Task.sleep(for: .seconds(interval))
        }
    }

    /// One pass of the control loop. Public for tests.
    func reconcileOnce() async throws {
        let state = runState.withLock { $0 }
        await statusBox.modify {
            $0.running = state.running
            $0.paused = state.paused
        }

        // Forges that failed at startup get another chance (backed off).
        await retryDetachedForgesIfDue()

        let records = store.all

        // 1. Clean up finished/failed VMs.
        for record in records where record.phase == .failed {
            await deleteVMRecord(id: record.id, reason: "failed: \(record.error ?? "unknown")")
        }

        // 2. Ask each attached forge for demand and running-work attribution.
        // A forge is attached only when its platform's credential exists
        // (GitHub: PAT provided at construction; Gitea: token in Keychain —
        // verified in attachGiteaForgeIfNeeded), so VMs are never assigned
        // to a platform the user hasn't authorized.
        var queueDepth = 0
        var demandByForge: [String: Int] = [:]
        var demandByPool: [RuntimeID: Int] = [:]
        let attached = forgeState.withLock { Array($0.byPlatform.values) }
        if !state.paused {
            var perForgeJobs: [String: (attribution: Bool, jobs: [ForgeJob])] = [:]
            for forge in attached {
                do {
                    let jobs = try await forge.queuedJobs()
                    // Org-scope forges contribute repo attribution; repo-scope
                    // forges suppress it (breakdown would carry no info).
                    perForgeJobs[forge.account] = (forge.attributesByRepo, jobs)
                    demandByForge[forge.account] = jobs.count
                    queueDepth += jobs.count
                    // Stage 2: bucket the same jobs into label pools so the
                    // spawn loop can pick the right runtime per instance.
                    for (poolID, count) in routing.demandByPool(for: jobs, forgeID: forge.id) {
                        demandByPool[poolID, default: 0] += count
                    }
                } catch {
                    let message = (error as? LocalizedError)?.errorDescription ?? "\(error)"
                    Log.warn("engine", "could not fetch \(forge.name) queue: \(message)")
                    await statusBox.modify { $0.lastError = message }
                }
            }
            let byRepo = ForgeDemand.mergeQueueByRepo(perForgeJobs)
            await statusBox.modify {
                $0.queueDepth = queueDepth
                $0.queueByRepo = byRepo
            }

            // Stamp each VM with the repos of the jobs its runners are
            // currently executing (attribution where the forge exposes it).
            // Runner names are VM ids, so one pass stamps each VM whichever
            // account it serves. Every attached forge contributes: GitHub
            // carries repo attribution per job; Gitea (and Forgejo) attribute
            // busy runners per VM. A failed forge is skipped, but if none
            // answered the stamps are left as they were.
            var runningAll: [RunningJob] = []
            var answered = false
            for forge in attached {
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
        } else {
            // Paused: clear attribution so stale repos don't linger.
            await statusBox.modify { $0.runningByRepo = nil }
            await clearRunningAttribution()
        }

        // 3. Decide desired count.
        let desired = Autoscaler.desiredCount(
            queueDepth: queueDepth,
            minRunners: config.minRunners,
            maxRunners: config.maxRunners,
            capacityCap: capacity.maxConcurrent,
            runnersPerVM: max(1, config.runnersPerVM)
        )

        await statusBox.modify {
            $0.desired = desired
            $0.capacityCap = capacity.maxConcurrent
            $0.jobCapacity = Autoscaler.jobCapacity(
                maxRunners: config.maxRunners,
                capacityCap: capacity.maxConcurrent,
                runnersPerVM: max(1, config.runnersPerVM)
            )
            $0.records = store.all
            $0.updatedAt = Date()
        }

        guard !state.paused else { return }

        // 4. Spawn up to desired — but never past what the disk can hold.
        // The plan-time cap uses the last probed free space; this re-probe
        // catches queue bursts that would otherwise fill the disk between
        // spawns. Host-runtime slots cost no disk, so they skip the guard.
        let currentActive = store.all.filter { $0.phase.isActive }.count
        var toSpawn = desired - currentActive
        if toSpawn > 0 {
            Log.info("engine", "scaling up: \(currentActive) active, want \(desired) (queue \(queueDepth))")
        }
        var diskPressureMessage: String?
        while toSpawn > 0 {
            let id = VMRecord.newName()
            var record = VMRecord(id: id, phase: .cloning)
            record.phase = .cloning
            // Per-VM platform assignment: the forge with the most unmet
            // demand (its queued jobs minus VMs already serving it). Only
            // attached forges are candidates — and forges only attach when
            // their platform's token exists, so a VM is never assigned a
            // platform the user has no credential for.
            let assigned = ForgeDemand.assignAccount(
                demand: demandByForge,
                active: activeByPlatform(),
                attached: Set(attached.map(\.account))
            )
            record.platform = assigned
            // Per-VM runtime assignment: the label pool with the most unmet
            // demand, within its capacity partition. Single-pool fleets
            // reduce to the primary runtime with the fleet cap.
            let chosen = selectRuntime(
                demand: demandByPool,
                active: activeByRuntime(),
                caps: capsByRuntime,
                fallback: routing.defaultRuntime
            )
            record.runtime = chosen.rawValue
            record.poolLabels = chosen.rawValue
            if chosen != .host {
                let diskPerVM = ResourceProbe.effectiveDiskPerVMGB(diskGB: config.diskGB, runtime: chosen.rawValue)
                let freeDisk = hostProbe().freeDiskGB
                let needed = diskPerVM + config.reserve.diskGB
                if freeDisk < needed {
                    diskPressureMessage =
                        "disk pressure: \(freeDisk) GB free, a new \(chosen.rawValue) instance needs \(diskPerVM) GB + \(config.reserve.diskGB) GB reserve — holding spawns"
                    break
                }
            }
            store.upsert(record)
            spawnLifecycle(for: record)
            toSpawn -= 1
            // Stagger spawns slightly so disk I/O doesn't stampede.
            try? await Task.sleep(for: .milliseconds(1500))
        }
        if let diskPressureMessage {
            Log.warn("engine", diskPressureMessage)
            await statusBox.modify { $0.lastError = diskPressureMessage }
        } else {
            // Spawns resumed: clear a stale disk-pressure message (other
            // errors belong to their own flows).
            await statusBox.modify {
                if $0.lastError?.contains("disk pressure") == true { $0.lastError = nil }
            }
        }

        // 5. Scale down: if we have more ready instances than desired, delete
        // idle ones — but never from a pool whose jobs are still waiting.
        if currentActive > desired {
            let idle = store.all
                .filter { $0.phase == .ready }
                .sorted { $0.createdAt < $1.createdAt }
            var surplus = currentActive - desired
            for record in idle where surplus > 0 {
                let poolID = RuntimeID(rawValue: record.runtime ?? "") ?? routing.defaultRuntime
                let unmet = (demandByPool[poolID] ?? 0) - (activeByRuntime()[poolID] ?? 0)
                guard unmet <= 0 else { continue }  // this pool still needs capacity
                Log.info("engine", "scaling down: deleting idle \(record.id)")
                await deleteVMRecord(id: record.id, reason: "scale down")
                surplus -= 1
            }
        }
    }

    /// Active VM counts by assigned account (`VMRecord.platform` holds the
    /// account name; the legacy accounts are "github" and "gitea").
    func activeByPlatform() -> [String: Int] {
        var counts: [String: Int] = [:]
        for record in store.all where record.phase.isActive {
            guard let account = record.platform else { continue }
            counts[account, default: 0] += 1
        }
        return counts
    }

    /// Active instance counts by runtime (mixed fleets partition capacity
    /// per runtime, so scale-up selection counts this way too).
    func activeByRuntime() -> [RuntimeID: Int] {
        var counts: [RuntimeID: Int] = [:]
        for record in store.all where record.phase.isActive {
            let id = RuntimeID(rawValue: record.runtime ?? "") ?? .tart
            counts[id, default: 0] += 1
        }
        return counts
    }

    /// The runtime instance executing a record's workload (mixed fleets:
    /// per-record; legacy: the engine's single runtime). Dispatches through
    /// the runtime map; the fallback is the engine's primary runtime.
    func runtime(for record: VMRecord) -> any Runtime {
        if let id = RuntimeID(rawValue: record.runtime ?? ""), let instance = runtimesByRuntime[id] {
            return instance
        }
        return runtime
    }

    /// The label pool a record belongs to (nil → the forge's fleet labels).
    func poolLabels(for record: VMRecord) -> [String]? {
        guard let poolName = record.poolLabels else { return nil }
        return routing.pools[RuntimeID(rawValue: poolName) ?? .tart]?.labels
    }

    /// Pick the runtime for a new instance: among pools with unmet demand,
    /// the one with the most unmet jobs — never beyond its capacity
    /// partition. Deterministic tie-breaks (alphabetical runtime id); with
    /// no demand anywhere, the default runtime wins.
    func selectRuntime(demand: [RuntimeID: Int], active: [RuntimeID: Int], caps: [RuntimeID: Int], fallback: RuntimeID)
        -> RuntimeID
    {
        var best: RuntimeID = fallback
        var bestUnmet = -1
        for (id, unmet) in demand.sorted(by: { $0.key.rawValue < $1.key.rawValue }) {
            guard routing.poolExists(id) else { continue }
            let cap = caps[id] ?? Int.max
            let running = active[id] ?? 0
            guard running < cap else { continue }  // partition exhausted
            let effective = min(unmet, cap - running)
            if effective > bestUnmet {
                bestUnmet = effective
                best = id
            }
        }
        return best
    }

    // MARK: - Running-job attribution

    /// Group repositories into a repo → count map. Org scope only: a
    /// single-repo fleet's breakdown carries no information (nil), while an
    /// org fleet always reports a map — empty when the API omitted repos.
    func attributionByRepo(_ repos: [String?]) -> [String: Int]? {
        guard githubOrgScoped else { return nil }
        return Dictionary(grouping: repos.compactMap { $0 }, by: { $0 }).mapValues(\.count)
    }

    /// Stamp VM records with the repositories whose jobs are currently
    /// executing on them (via runner_name → VM mapping), and aggregate the
    /// same data into `FleetStatus.runningByRepo`. Also fills the per-VM
    /// `job` label (first running job name) for the status surfaces.
    /// Repo scope stamps the job name only — the repo breakdown would carry
    /// no information there (mirrors `queueByRepo` suppression).
    func applyRunningAttribution(_ running: [RunningJob]) async {
        let isOrgScope = githubOrgScoped

        // Map runner name → VM id. Single-runner VMs register under the VM
        // id itself; multi-runner VMs register as "<vmid>-r1…rN".
        var reposByVM: [String: [String]] = [:]
        var jobByVM: [String: String] = [:]
        for job in running {
            guard let runnerName = job.runnerName,
                let vmID = vmID(forRunnerName: runnerName)
            else { continue }
            if isOrgScope, let repo = job.repository {
                reposByVM[vmID, default: []].append(repo)
            }
            if jobByVM[vmID] == nil { jobByVM[vmID] = job.name }
        }

        await statusBox.modify {
            $0.runningByRepo = isOrgScope ? attributionByRepo(running.compactMap(\.repository)) : nil
        }

        // Stamp VMs that exist; clear the stamp on VMs whose jobs finished.
        for record in store.all {
            let repos = reposByVM[record.id]?.sorted()
            let job = jobByVM[record.id]
            if record.repos != repos || record.job != job {
                updateRecord(record.id) {
                    $0.repos = repos
                    $0.job = job
                }
            }
        }
    }

    /// The VM id owning a GitHub runner name, among the VMs we track.
    func vmID(forRunnerName runnerName: String) -> String? {
        for record in store.all {
            if runnerName == record.id { return record.id }
            let prefix = "\(record.id)-r"
            if runnerName.hasPrefix(prefix),
                let index = Int(runnerName.dropFirst(prefix.count)),
                (1...max(1, config.runnersPerVM)).contains(index)
            {
                return record.id
            }
        }
        return nil
    }

    /// Drop the attribution stamp from every record (pause path).
    func clearRunningAttribution() async {
        for record in store.all {
            if record.repos != nil || record.job != nil {
                updateRecord(record.id) {
                    $0.repos = nil
                    $0.job = nil
                }
            }
        }
    }

}
