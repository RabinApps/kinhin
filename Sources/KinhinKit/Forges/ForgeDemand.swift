import Foundation

// MARK: - Demand merging (multi-forge autoscaler)

enum ForgeDemand {
    /// Merge queued jobs across forges into repo → count. Each contributing
    /// forge carries `attribution: Bool` — a repo-scoped forge suppresses its
    /// breakdown (it would carry no information), org-scoped forges keep it.
    static func mergeQueueByRepo(_ perForge: [ForgeID: (attribution: Bool, jobs: [ForgeJob])]) -> [String: Int]? {
        merge(perForge)
    }

    /// Account-keyed variant (the engine keys demand by account name).
    static func mergeQueueByRepo(_ perForge: [String: (attribution: Bool, jobs: [ForgeJob])]) -> [String: Int]? {
        merge(perForge)
    }

    private static func merge<Key: Hashable>(_ perForge: [Key: (attribution: Bool, jobs: [ForgeJob])])
        -> [String: Int]?
    {
        var merged: [String: Int] = [:]
        var any = false
        for (_, entry) in perForge where entry.attribution {
            any = true
            for job in entry.jobs {
                if let repo = job.repository {
                    merged[repo, default: 0] += 1
                }
            }
        }
        return any ? merged : nil
    }

    /// Pick the platform for a new VM: the attached forge with the largest
    /// unmet demand (queued jobs minus VMs already serving it). Ties prefer
    /// GitHub (the original platform): it is evaluated first and later
    /// forges need strictly greater unmet demand to take over.
    static func assignPlatform(demand: [ForgeID: Int], active: [ForgeID: Int], attached: Set<ForgeID>) -> ForgeID {
        var best: ForgeID = .github
        var bestUnmet = Int.min
        let ordered = attached.sorted { a, b in
            if a == .github { return true }
            if b == .github { return false }
            return a.rawValue < b.rawValue
        }
        for forge in ordered {
            let unmet = (demand[forge] ?? 0) - (active[forge] ?? 0)
            if unmet > bestUnmet {
                bestUnmet = unmet
                best = forge
            }
        }
        return best
    }

    /// Account-keyed variant of `assignPlatform`: the account with the
    /// largest unmet demand wins; ties prefer the legacy `github` account,
    /// then alphabetical order. With nothing attached it returns "github".
    static func assignAccount(demand: [String: Int], active: [String: Int], attached: Set<String>) -> String {
        var best = ForgeID.github.rawValue
        var bestUnmet = Int.min
        let ordered = attached.sorted { a, b in
            if a == ForgeID.github.rawValue { return true }
            if b == ForgeID.github.rawValue { return false }
            return a < b
        }
        for account in ordered {
            let unmet = (demand[account] ?? 0) - (active[account] ?? 0)
            if unmet > bestUnmet {
                bestUnmet = unmet
                best = account
            }
        }
        return best
    }
}
