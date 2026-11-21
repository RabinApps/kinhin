import Foundation

extension ScalePlan {
    /// The account that gets the next instance on `runtime`, from the queue's point of view.
    ///
    /// Only accounts that have demand on `runtime` are candidates: the instance is registered with that account, so
    /// it must be able to serve a job there. Among them, demand and coverage are counted on `runtime` alone (an
    /// instance on another runtime cannot serve these jobs), and with queue dates the account whose next uncovered
    /// job on `runtime` was created earliest wins (first in, first out); "uncovered" advances as instances on
    /// `runtime` cover an account's jobs, so one slot never starves an account whose job is next in line. Without
    /// dates the account with the most unmet demand wins, as it always did. With no account queued on `runtime`,
    /// every account stays a candidate and the account-wide totals decide.
    static func account(for runtime: RuntimeID, totals: [String: Int], records: [VMRecord], input: Input) -> String {
        var coverage: [String: Int] = [:]
        var onRuntime: [String: Int] = [:]
        for record in records where covers(record, includesRunning: input.includesRunning) {
            guard let account = record.platform else { continue }
            coverage[account, default: 0] += 1
            if pool(of: record, input: input) == runtime { onRuntime[account, default: 0] += 1 }
        }
        var attached = input.attached
        let narrowed = attached.intersection(input.demand.filter { ($0.value[runtime] ?? 0) > 0 }.keys)
        let queuedHere = !narrowed.isEmpty
        if queuedHere { attached = narrowed }
        var oldest: [String: Date] = [:]
        let jobsPerInstance = max(1, input.runnersPerVM)
        for (account, byRuntime) in input.queueDatesByAccount {
            guard let dates = byRuntime[runtime] else { continue }
            let covered = (onRuntime[account] ?? 0) * jobsPerInstance
            if covered < dates.count { oldest[account] = dates[covered] }
        }
        return ForgeDemand.assignAccount(
            demand: queuedHere ? input.demand.mapValues { $0[runtime] ?? 0 } : totals,
            active: queuedHere ? onRuntime : coverage, attached: attached, oldest: oldest)
    }
}
