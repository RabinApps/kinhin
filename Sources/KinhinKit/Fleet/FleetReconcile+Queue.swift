import Foundation

/// The queue as the status publishes it: oldest-created first, with the forge each job came from.
extension FleetEngine {
    /// A pass's queue, merged across forges.
    struct QueueSnapshot {
        /// Waiting jobs, first-in first-out, positions filled (capped at `FleetStatus.queuedJobsLimit`).
        var entries: [FleetJobsReport.Entry]
        /// Waiting jobs per forge account (every job, not only the capped head).
        var byForge: [String: Int]
        /// Each account's jobs' created dates, oldest first, for the scale plan's first-in first-out account choice.
        /// Every job counts (a scale-set runner's job too): the plan's coverage counts them the same way.
        var datesByForge: [String: [Date]]
    }

    /// Fold each forge's (already FIFO-ordered) jobs into one queue. A job a scale-set runner already took is
    /// counted in demand but is not waiting, so it is left out here.
    static func queueSnapshot(_ perForge: [(account: String, jobs: [ForgeJob])]) -> QueueSnapshot {
        var entries: [FleetJobsReport.Entry] = []
        var byForge: [String: Int] = [:]
        var dates: [String: [Date]] = [:]
        for (account, jobs) in perForge {
            let waiting = jobs.filter { !$0.isAssigned }
            byForge[account] = waiting.count
            let created = jobs.compactMap { $0.correlation?.enqueuedAt }.sorted()
            if !created.isEmpty { dates[account] = created }
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
