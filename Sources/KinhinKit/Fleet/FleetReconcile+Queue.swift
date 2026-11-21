import Foundation

/// The queue as the status publishes it: oldest-created first, with the forge each job came from.
extension FleetEngine {
    /// A pass's queue, merged across forges.
    struct QueueSnapshot {
        /// Waiting jobs, first-in first-out, positions filled (capped at `FleetStatus.queuedJobsLimit`).
        var entries: [FleetJobsReport.Entry]
        /// Waiting jobs per forge account (every job, not only the capped head).
        var byForge: [String: Int]
        /// Each account's jobs' created dates per runtime, for the scale plan's first-in first-out account choice:
        /// jobs a scale-set runner already took first (their runners count as coverage), then the waiting jobs
        /// oldest first, so advancing past the covered prefix lands on the oldest job that is still waiting.
        var datesByForge: [String: [RuntimeID: [Date]]]
    }

    /// Fold each forge's (already FIFO-ordered) jobs into one queue. A job a scale-set runner already took is
    /// counted in demand but is not waiting, so it is left out here.
    static func queueSnapshot(
        _ perForge: [(account: String, jobs: [ForgeJob])], runtime: (ForgeJob) -> RuntimeID
    ) -> QueueSnapshot {
        var entries: [FleetJobsReport.Entry] = []
        var byForge: [String: Int] = [:]
        var dates: [String: [RuntimeID: [Date]]] = [:]
        for (account, jobs) in perForge {
            let waiting = jobs.filter { !$0.isAssigned }
            byForge[account] = waiting.count
            // Per runtime, since an instance only serves jobs routed to its own runtime. An undated taken job still
            // occupies a runner, so it keeps its place (as the oldest).
            var taken: [RuntimeID: [Date]] = [:]
            var waitingDates: [RuntimeID: [Date]] = [:]
            for job in jobs {
                let pool = runtime(job)
                if job.isAssigned {
                    taken[pool, default: []].append(job.correlation?.enqueuedAt ?? .distantPast)
                } else if let created = job.correlation?.enqueuedAt {
                    waitingDates[pool, default: []].append(created)
                }
            }
            for pool in Set(taken.keys).union(waitingDates.keys) {
                let ordered = (taken[pool] ?? []).sorted() + (waitingDates[pool] ?? []).sorted()
                if !ordered.isEmpty { dates[account, default: [:]][pool] = ordered }
            }
            for job in waiting {
                entries.append(
                    FleetJobsReport.Entry(
                        name: job.name, repo: job.repository, forge: account,
                        enqueuedAt: job.correlation?.enqueuedAt))
            }
        }
        let ordered = FleetJobsReport.fifo(entries)
        return QueueSnapshot(
            entries: Array(ordered.prefix(FleetStatus.queuedJobsLimit)), byForge: byForge, datesByForge: dates)
    }

    /// Running jobs with a job two forges both reported counted once: the same runner, job and repository.
    /// Jobs with no runner name cannot be told apart, so they all stay.
    static func deduplicated(_ jobs: [RunningJob]) -> [RunningJob] {
        var seen: Set<String> = []
        return jobs.filter { job in
            guard let runner = job.runnerName else { return true }
            return seen.insert("\(runner)\u{1F}\(job.name)\u{1F}\(job.repository ?? "")").inserted
        }
    }
}
