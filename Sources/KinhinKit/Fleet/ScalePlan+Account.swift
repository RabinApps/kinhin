import Foundation

extension ScalePlan {
    /// The account that gets the next instance on `runtime`, from the queue's point of view.
    ///
    /// Only accounts that have demand on `runtime` are candidates: the instance is registered with that account, so
    /// it must be able to serve a job there (with no account queued on `runtime`, every account stays a candidate).
    /// Among them, with queue dates, the account whose next uncovered job was created earliest wins (first in, first
    /// out); "uncovered" advances as planned instances cover an account's jobs, so one slot never starves an account
    /// whose job is next in line. Without dates the account with the most unmet demand wins, as it always did.
    static func account(for runtime: RuntimeID, totals: [String: Int], coverage: [String: Int], input: Input) -> String
    {
        var attached = input.attached
        let onRuntime = Set(input.demand.filter { ($0.value[runtime] ?? 0) > 0 }.keys)
        let narrowed = attached.intersection(onRuntime)
        if !narrowed.isEmpty { attached = narrowed }
        var oldest: [String: Date] = [:]
        let jobsPerInstance = max(1, input.runnersPerVM)
        for (account, dates) in input.queueDatesByAccount {
            let covered = (coverage[account] ?? 0) * jobsPerInstance
            if covered < dates.count { oldest[account] = dates[covered] }
        }
        return ForgeDemand.assignAccount(demand: totals, active: coverage, attached: attached, oldest: oldest)
    }
}
