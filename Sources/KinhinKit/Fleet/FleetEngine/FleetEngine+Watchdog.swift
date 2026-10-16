import Foundation

// MARK: - Watchdog settings

/// Timings of the checks that catch instances dying behind the engine's back.
/// Production defaults; tests shorten them.
public struct Watchdog: Sendable {
    /// How often a runner watch asks the runtime whether its instance is alive.
    public var livenessInterval: Duration
    /// Consecutive "stopped or gone" answers before the instance is declared
    /// dead (one answer can be a race with a restart).
    public var livenessMisses: Int
    /// How often the engine compares the runtimes' instances with its records.
    public var orphanSweepInterval: Duration
    /// How long an instance with no record may exist before it is removed.
    public var orphanGrace: Duration
    /// Allowance for the agents in a booted instance to show up on the forge
    /// (never below `vm_boot_timeout`).
    public var registrationGrace: Duration
    /// How long every runner of an idle-grace forge (Gitea, Forgejo) must sit
    /// idle before its instance counts as finished: the next task may still be
    /// dispatching when the last one ends.
    public var idleGrace: Duration
    /// How long a record nothing drives (a warm instance) must have been
    /// unchanged before a missing or stopped instance counts as vanished: a
    /// spawn writes its record a moment before its lifecycle task exists.
    public var unwatchedGrace: Duration

    public init(
        livenessInterval: Duration = .seconds(15), livenessMisses: Int = 3,
        orphanSweepInterval: Duration = .seconds(120), orphanGrace: Duration = .seconds(600),
        registrationGrace: Duration = .seconds(120), idleGrace: Duration = .seconds(30),
        unwatchedGrace: Duration = .seconds(30)
    ) {
        self.livenessInterval = livenessInterval
        self.livenessMisses = livenessMisses
        self.orphanSweepInterval = orphanSweepInterval
        self.orphanGrace = orphanGrace
        self.registrationGrace = registrationGrace
        self.idleGrace = idleGrace
        self.unwatchedGrace = unwatchedGrace
    }
}

extension Duration {
    var timeInterval: TimeInterval { Double(components.seconds) + Double(components.attoseconds) / 1e18 }
}

/// What the orphan sweep remembers between passes.
struct OrphanState: Sendable {
    /// When each unmanaged instance was first seen without a record.
    var firstSeen: [String: Date] = [:]
    /// When each forge-side runner record of ours (no instance record, not
    /// online) was first seen, keyed `account/runnerID`.
    var runnerFirstSeen: [String: Date] = [:]
    var lastSweep: Date?
}

// MARK: - Liveness

extension FleetEngine {
    /// What one liveness check concluded.
    enum Liveness: Equatable {
        case alive
        case dead(InstanceState)
        /// The runtime could not be asked; says nothing about the instance.
        case unknown
    }

    /// Asks the instance's runtime whether it still exists and runs.
    func liveness(of id: String) async -> Liveness {
        var probe = VMRecord(id: id, phase: .ready)
        probe.runtime = store.all.first { $0.id == id }?.runtime
        do {
            switch try await runtime(for: probe).state(id: id) {
            case .running: return .alive
            case let state: return .dead(state)
            }
        } catch is CancellationError {
            return .unknown
        } catch {
            Log.warn(id, "could not check whether the instance is alive: \(error.localizedDescription)")
            return .unknown
        }
    }

    // MARK: - Orphans

    /// Instance names this build generates (`VMRecord.newName`). Only these
    /// are ever removed as orphans: baked images, build scratch VMs and
    /// anything a user named by hand share the `kinhin-` prefix but are not
    /// runner instances.
    static func isGeneratedInstanceName(_ name: String) -> Bool {
        name.range(of: InstanceNaming.generatedNamePattern, options: .regularExpression) != nil
    }

    /// Runs the orphan sweep when its interval has elapsed.
    func sweepOrphansIfDue(now: Date = Date()) async {
        let due = orphanState.withLock { state -> Bool in
            let interval = watchdog.orphanSweepInterval.timeInterval
            if let last = state.lastSweep, now.timeIntervalSince(last) < interval { return false }
            state.lastSweep = now
            return true
        }
        if due {
            await sweepOrphans(now: now)
            await sweepOrphanRunnerRecords(now: now)
            await sweepUnwatchedRecords(now: now)
        }
    }

    // MARK: - Unwatched records

    /// Removes active records nothing drives (a warm instance waits with no
    /// lifecycle task, so no liveness watch) whose instance was deleted or
    /// stopped behind the engine's back. Left alone, such a record holds a
    /// `max_runners` slot until a job claims it, and the claim then fails and
    /// counts against the runtime's spawn backoff. One listing per runtime;
    /// a runtime that can't be asked says nothing about its records. Each
    /// removal is noted in the healing journal.
    func sweepUnwatchedRecords(now: Date = Date()) async {
        let grace = watchdog.unwatchedGrace.timeInterval
        let driven = lifecycleTasks.withLock { Set($0.keys) }
        let deleting = deletes.withLock { $0.inFlight.union($0.tasks.keys) }
        let unwatched = store.all.filter {
            $0.phase.isActive && !driven.contains($0.id) && !deleting.contains($0.id)
                && now.timeIntervalSince($0.updatedAt) >= grace
        }
        let byRuntime = Dictionary(grouping: unwatched) { $0.runtimeID ?? .tart }
        for (runtimeID, records) in byRuntime.sorted(by: { $0.key.rawValue < $1.key.rawValue }) {
            guard let runtime = runtimesByRuntime[runtimeID] else { continue }
            let states: [String: InstanceState]
            do {
                states = try await runtime.states(of: records.map(\.id))
            } catch is CancellationError {
                return
            } catch {
                Log.warn(
                    "engine", "could not check unwatched \(runtimeID.rawValue) instances: \(error.localizedDescription)"
                )
                continue
            }
            for record in records {
                guard let state = states[record.id], state != .running else { continue }
                // Claimed (or started deleting) while we were listing: its lifecycle owns it now.
                guard lifecycleTasks.withLock({ $0[record.id] == nil }) else { continue }
                let what = state == .gone ? "no longer exists" : "was stopped outside kinhin"
                let detail = "\(record.phase.rawValue) instance \(record.id) \(what)"
                Log.warn(record.id, "\(detail); removing its record")
                guard scheduleDelete(id: record.id, reason: detail) else { continue }
                healing.note(
                    HealingSignal(
                        kind: .instanceGone, subject: record.id, detail: detail,
                        evidence: state == .stopped ? .instanceStopped : nil),
                    fix: Remediation(.recycleInstance, subject: record.id),
                    detail: "removing \(record.id); a replacement starts if work is waiting")
            }
        }
    }

    /// Removes runner records on the forge that name an instance this engine
    /// has no record of and whose agent is not connected. Forges that create
    /// the runner before the agent starts (GitLab, Bitbucket) and agents that
    /// failed their own deregistration (Azure DevOps) leave such records when
    /// the engine or host dies between registration and teardown, and nothing
    /// else ever deletes them.
    ///
    /// Only generated instance names are touched, only offline records, and
    /// only after they stay unclaimed for `orphanGrace`, which is longer than
    /// the registration grace: another engine sharing the account is mid
    /// registration for far less. An online runner is never removed.
    func sweepOrphanRunnerRecords(now: Date = Date()) async {
        let known = Set(store.all.map(\.id))
        let grace = watchdog.orphanGrace.timeInterval
        let attached = forgeState.withLock { Array($0.byPlatform.values) }
        var stillOrphaned: Set<String> = []
        var listed: Set<String> = []
        for forge in attached {
            let runners: [ForgeRunner]
            do {
                runners = try await runnerDirectory.freshRunners(of: forge)
            } catch is CancellationError {
                return
            } catch {
                // No runner list (or a failing one): says nothing about records.
                continue
            }
            listed.insert(forge.account)
            for runner in runners where !runner.online && !runner.busy {
                let instance = Self.instanceName(ofRunner: runner.name)
                guard Self.isGeneratedInstanceName(instance), !known.contains(instance) else { continue }
                let key = "\(forge.account)/\(runner.id)"
                stillOrphaned.insert(key)
                let first = orphanState.withLock { state -> Date in
                    if let seen = state.runnerFirstSeen[key] { return seen }
                    state.runnerFirstSeen[key] = now
                    return now
                }
                guard now.timeIntervalSince(first) >= grace else { continue }
                // A record created while we were listing makes it managed.
                guard !store.all.contains(where: { $0.id == instance }) else { continue }
                Log.warn(
                    "engine",
                    "removing orphaned \(forge.name) runner record \(runner.name): no instance record for \(Int(grace))s"
                )
                do {
                    try await forge.deleteRunner(id: runner.id)
                    runnerDirectory.invalidate(account: forge.account)
                    orphanState.withLock { _ = $0.runnerFirstSeen.removeValue(forKey: key) }
                    stillOrphaned.remove(key)
                } catch is CancellationError {
                    return
                } catch {
                    Log.warn("engine", "could not remove orphaned runner \(runner.name): \(error.localizedDescription)")
                }
            }
        }
        // Forget records that are gone, but only for accounts we could re-list.
        orphanState.withLock { state in
            state.runnerFirstSeen = state.runnerFirstSeen.filter { entry in
                let account = entry.key.split(separator: "/", maxSplits: 1).first.map(String.init) ?? ""
                return !listed.contains(account) || stillOrphaned.contains(entry.key)
            }
        }
    }

    /// The instance a runner name belongs to: a runner of an instance hosting
    /// several is named `<instance>-r<N>`.
    static func instanceName(ofRunner name: String) -> String {
        if let range = name.range(of: #"-r\d+$"#, options: .regularExpression) {
            return String(name[..<range.lowerBound])
        }
        return name
    }

    /// Compares every runtime's instances with the store. An instance of ours
    /// with no record is surfaced as a status alert, and removed once it has
    /// stayed unmanaged past the grace period (a record is always written
    /// before an instance exists, so a lasting mismatch is a leak: a teardown
    /// cut short, or a crash between clone and record).
    func sweepOrphans(now: Date = Date()) async {
        let known = Set(store.all.map(\.id))
        var unmanaged: [String: RuntimeID] = [:]
        var unlisted: Set<RuntimeID> = []
        for (runtimeID, instance) in runtimesByRuntime.sorted(by: { $0.key.rawValue < $1.key.rawValue }) {
            do {
                for name in try await instance.existingInstanceIDs()
                where Self.isGeneratedInstanceName(name) && !known.contains(name) {
                    unmanaged[name] = runtimeID
                }
            } catch is CancellationError {
                return
            } catch {
                Log.warn("engine", "orphan sweep could not list \(runtimeID.rawValue): \(error.localizedDescription)")
                unlisted.insert(runtimeID)
            }
        }
        // A record created while we were listing makes its instance managed.
        let nowKnown = Set(store.all.map(\.id))
        unmanaged = unmanaged.filter { !nowKnown.contains($0.key) }

        let grace = watchdog.orphanGrace.timeInterval
        let overdue = orphanState.withLock { state -> [String] in
            // Forget what is gone; keep what could not be re-checked.
            if unlisted.isEmpty { state.firstSeen = state.firstSeen.filter { unmanaged[$0.key] != nil } }
            for name in unmanaged.keys where state.firstSeen[name] == nil { state.firstSeen[name] = now }
            return unmanaged.keys.sorted().filter { now.timeIntervalSince(state.firstSeen[$0] ?? now) >= grace }
        }

        var failed: [String] = []
        for name in overdue {
            guard let owner = unmanaged[name], let instance = runtimesByRuntime[owner] else { continue }
            Log.warn("engine", "removing orphaned \(owner.rawValue) instance \(name): no record for \(Int(grace))s")
            do {
                try await instance.teardown(id: name)
                orphanState.withLock { _ = $0.firstSeen.removeValue(forKey: name) }
                unmanaged[name] = nil
            } catch is CancellationError {
                return
            } catch {
                Log.error("engine", "could not remove orphaned instance \(name): \(error.localizedDescription)")
                failed.append(name)
            }
        }

        let message: String? =
            unmanaged.isEmpty
            ? nil
            : "unmanaged instance(s) with no record: \(unmanaged.keys.sorted().joined(separator: ", "))"
                + (failed.isEmpty
                    ? " (removed if they stay unclaimed)" : " (removal failed: \(failed.joined(separator: ", ")))")
        await statusBox.modify { $0.setAlert("orphans", message) }
    }
}
