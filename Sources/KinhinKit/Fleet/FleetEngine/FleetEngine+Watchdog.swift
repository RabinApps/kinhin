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

    public init(
        livenessInterval: Duration = .seconds(15), livenessMisses: Int = 3,
        orphanSweepInterval: Duration = .seconds(120), orphanGrace: Duration = .seconds(600)
    ) {
        self.livenessInterval = livenessInterval
        self.livenessMisses = livenessMisses
        self.orphanSweepInterval = orphanSweepInterval
        self.orphanGrace = orphanGrace
    }
}

extension Duration {
    var timeInterval: TimeInterval { Double(components.seconds) + Double(components.attoseconds) / 1e18 }
}

/// What the orphan sweep remembers between passes.
struct OrphanState: Sendable {
    /// When each unmanaged instance was first seen without a record.
    var firstSeen: [String: Date] = [:]
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
        name.range(of: #"^kinhin-\d{9,11}-[0-9a-f]{4,8}$"#, options: .regularExpression) != nil
    }

    /// Runs the orphan sweep when its interval has elapsed.
    func sweepOrphansIfDue(now: Date = Date()) async {
        let due = orphanState.withLock { state -> Bool in
            let interval = watchdog.orphanSweepInterval.timeInterval
            if let last = state.lastSweep, now.timeIntervalSince(last) < interval { return false }
            state.lastSweep = now
            return true
        }
        if due { await sweepOrphans(now: now) }
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
