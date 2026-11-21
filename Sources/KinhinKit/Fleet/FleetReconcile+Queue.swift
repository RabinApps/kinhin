import Foundation

/// The queue as the status publishes it: oldest-created first, with the forge each job came from.
extension FleetEngine {
    /// A pass's queue, merged across forges.
    struct QueueSnapshot {
        /// Waiting jobs, first-in first-out, positions filled (capped at `FleetStatus.queuedJobsLimit`).
        var entries: [FleetJobsReport.Entry]
        /// Waiting jobs per forge account (every job, not only the capped head).
        var byForge: [String: Int]
        /// Each account's longest-waiting job, for the scale plan's first-in first-out account choice.
        var oldestByForge: [String: Date]
    }

    /// Fold each forge's (already FIFO-ordered) jobs into one queue. A job a scale-set runner already took is
    /// counted in demand but is not waiting, so it is left out here.
    static func queueSnapshot(_ perForge: [(account: String, jobs: [ForgeJob])]) -> QueueSnapshot {
        var entries: [FleetJobsReport.Entry] = []
        var byForge: [String: Int] = [:]
        var oldest: [String: Date] = [:]
        for (account, jobs) in perForge {
            let waiting = jobs.filter { !$0.isAssigned }
            byForge[account] = waiting.count
            if let first = waiting.compactMap({ $0.correlation?.enqueuedAt }).min() { oldest[account] = first }
            for job in waiting {
                entries.append(
                    FleetJobsReport.Entry(
                        name: job.name, repo: job.repository, forge: account,
                        enqueuedAt: job.correlation?.enqueuedAt))
            }
        }
        let ordered = FleetJobsReport.fifo(entries)
        return QueueSnapshot(
            entries: Array(ordered.prefix(FleetStatus.queuedJobsLimit)), byForge: byForge, oldestByForge: oldest)
    }
}
