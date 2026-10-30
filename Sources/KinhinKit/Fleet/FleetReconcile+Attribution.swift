import Foundation

// FleetEngine — pool counters, runtime selection, and running-job attribution.

extension FleetEngine {
    /// The runtime instance executing a record's workload (mixed fleets:
    /// per-record; legacy: the engine's single runtime). Dispatches through
    /// the runtime map; the fallback is the engine's primary runtime.
    func runtime(for record: VMRecord) -> any Runtime {
        if let id = record.runtimeID, let instance = runtimesByRuntime[id] {
            return instance
        }
        return runtime
    }

    /// The labels of the pool a record's runtime serves, so its runners join
    /// the right `runs-on` pool (nil for records without a runtime → the
    /// forge's fleet labels).
    func poolLabels(for record: VMRecord) -> [String]? {
        guard let runtimeID = record.runtimeID else { return nil }
        let routerState = router.snapshot
        let images = routerState.images
        let pool = routerState.model.pools[runtimeID]?.labels
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
        guard attributesRunningByRepo else { return nil }
        return Dictionary(grouping: repos.compactMap { $0 }, by: { $0 }).mapValues(\.count)
    }

    /// Stamp VM records with the repositories whose jobs are currently
    /// executing on them (via runner_name → VM mapping), and aggregate the
    /// same data into `FleetStatus.runningByRepo`. Also fills the per-VM
    /// `runningJobs` (one stamp per busy runner) and the `job` label (the
    /// first stamp's name) for the status surfaces.
    /// Repo scope stamps the job name only — the repo breakdown would carry
    /// no information there (mirrors `queueByRepo` suppression).
    func applyRunningAttribution(_ running: [RunningJob]) async {
        let isOrgScope = attributesRunningByRepo

        // Map runner name → VM id. Single-runner VMs register under the VM
        // id itself; multi-runner VMs register as "<vmid>-r1…rN".
        var jobsByVM: [String: [RunningJobStamp]] = [:]
        let records = store.all
        let ids = Set(records.map(\.id))
        for job in running {
            guard let runnerName = job.runnerName,
                let vmID = Self.vmID(forRunnerName: runnerName, among: ids)
            else { continue }
            if let correlation = job.correlation {
                noteJobCorrelation(vm: vmID, correlation)
            } else {
                jobTrace(for: vmID)?.logContext.job = job.name
            }
            jobsByVM[vmID, default: []].append(
                RunningJobStamp(runner: runnerName, job: job.name, repo: isOrgScope ? job.repository : nil))
        }

        await statusBox.modify {
            $0.runningByRepo = isOrgScope ? attributionByRepo(running.compactMap(\.repository)) : nil
        }

        // Stamp VMs that exist; clear the stamp on VMs whose jobs finished.
        for record in records {
            let stamps = jobsByVM[record.id].map {
                $0.sorted {
                    (Self.runnerIndex($0.runner), $0.runner, $0.job) < (Self.runnerIndex($1.runner), $1.runner, $1.job)
                }
            }
            let repos = stamps.flatMap { stamps -> [String]? in
                let repos = Set(stamps.compactMap(\.repo))
                return repos.isEmpty ? nil : repos.sorted()
            }
            let job = stamps?.first?.job
            if record.repos != repos || record.job != job || record.runningJobs != stamps {
                updateRecord(record.id) {
                    $0.repos = repos
                    $0.job = job
                    $0.runningJobs = stamps
                }
            }
        }
    }

    /// The `N` of a `<id>-r<N>` runner name, 0 for a single-runner VM's bare id: numeric, so `-r2` sorts before `-r10`.
    static func runnerIndex(_ runnerName: String) -> Int {
        runnerName.range(of: "-r", options: .backwards).flatMap { Int(runnerName[$0.upperBound...]) } ?? 0
    }

    /// The VM id owning a runner name, among the tracked VM `ids`: the id
    /// itself, or `<id>-r<N>`. N is not bounded by the current `runnersPerVM`:
    /// a reload that lowers it must not orphan runners of VMs spawned under the
    /// old count. One set lookup per name instead of a scan (and copy) of the
    /// whole store.
    static func vmID(forRunnerName runnerName: String, among ids: Set<String>) -> String? {
        if ids.contains(runnerName) { return runnerName }
        guard let marker = runnerName.range(of: "-r", options: .backwards),
            let index = Int(runnerName[marker.upperBound...]), index >= 1
        else { return nil }
        let base = String(runnerName[..<marker.lowerBound])
        return ids.contains(base) ? base : nil
    }

    /// Drop the attribution stamp from every record (pause path).
    func clearRunningAttribution() async {
        for record in store.all {
            if record.repos != nil || record.job != nil || record.runningJobs != nil {
                updateRecord(record.id) {
                    $0.repos = nil
                    $0.job = nil
                    $0.runningJobs = nil
                }
            }
        }
    }
}
