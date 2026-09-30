import Foundation

// FleetEngine — pool counters, runtime selection, and running-job attribution.

extension FleetEngine {
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

    /// The labels of the pool a record's runtime serves, so its runners join
    /// the right `runs-on` pool (nil for records without a runtime → the
    /// forge's fleet labels).
    func poolLabels(for record: VMRecord) -> [String]? {
        guard let runtimeID = record.runtime.flatMap(RuntimeID.init(rawValue:)) else { return nil }
        return routing.pools[runtimeID]?.labels
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
