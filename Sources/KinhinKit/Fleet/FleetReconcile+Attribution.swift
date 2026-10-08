import Foundation

// FleetEngine — pool counters, runtime selection, and running-job attribution.

extension FleetEngine {
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
        let pool = routing.pools[runtimeID]?.labels
        // A tart instance cloned from a named image also advertises that image's labels, so
        // the jobs that ask for them (`runs-on: [..., xcode]`) can land on it.
        guard runtimeID == .tart, let pool, let image = record.image,
            let extra = images.first(where: { $0.name == image })?.labels
        else { return pool }
        // A Linux Tart VM must not advertise macOS-only fleet labels — otherwise
        // it would attract macOS jobs it cannot run. Strip them when the image's
        // base is a curated Linux image; custom/local names can't be reliably
        // identified, so they keep the fleet labels as-is.
        let labels: [String]
        if TartBaseImage.isLinux(images.first(where: { $0.name == image })?.baseImage) {
            labels = pool.filter { !macosOnlyLabel($0) }
        } else {
            labels = pool
        }
        return labels + extra.filter { label in !labels.contains { $0.caseInsensitiveCompare(label) == .orderedSame } }
    }

    /// Labels in the fleet's default set that are macOS-specific and must not
    /// be advertised by a Linux Tart runner.
    private func macosOnlyLabel(_ label: String) -> Bool {
        label.lowercased() == "macos"
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
