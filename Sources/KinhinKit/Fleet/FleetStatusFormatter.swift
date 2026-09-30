import Foundation

/// Human-readable renderings of a `FleetStatus`, shared by every surface:
/// the menu bar and Fleet tab (`summary`), `kinhin status`/`watch`
/// (`report`), and the per-VM rows. One place decides how a pause, a stale
/// queue or an org-scope breakdown reads.
public enum FleetStatusFormatter {
    // MARK: - Pieces

    /// "running", "paused" or "stopped".
    public static func state(_ status: FleetStatus) -> String {
        !status.running ? "stopped" : (status.paused ? "paused" : "running")
    }

    /// "acme/api ×3, acme/web ×1": repos by count, busiest first.
    public static func repoBreakdown(_ byRepo: [String: Int], limit: Int? = nil) -> String {
        let sorted = byRepo.sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }
        return (limit.map { Array(sorted.prefix($0)) } ?? sorted)
            .map { "\($0.key) ×\($0.value)" }
            .joined(separator: ", ")
    }

    /// A VM's repos in a few words: the repo, or "N repos". Nil when none.
    public static func repos(of record: VMRecord) -> String? {
        guard let repos = record.repos, !repos.isEmpty else { return nil }
        return repos.count == 1 ? repos[0] : "\(repos.count) repos"
    }

    /// The freshness note for the queue numbers (nil when never polled, or
    /// from an older daemon that predates the field).
    public static func queueAge(_ status: FleetStatus) -> String? {
        guard let age = status.queueAgeSeconds else { return nil }
        let stale = status.queueAgeIsStale == true ? " (stale — a forge poll failed or the engine is stopped)" : ""
        var slowed = ""
        if let reason = status.pollSlowdown, let current = status.currentPollInterval {
            slowed = " · checking every \(current)s (\(reason))"
        }
        return "\(age)s old\(stale)\(slowed)"
    }

    // MARK: - Summary (menu bar, Fleet tab)

    /// The state line with counters, plus indented notes: auto-resume while
    /// paused, queue freshness, and the org-scope repos (top 2) behind the
    /// queued and running work.
    public static func summary(_ status: FleetStatus?) -> String {
        guard let status else { return "Needs setup — open the Setup tab" }
        var line =
            "\(state(status).capitalized) — queue \(status.queueDepth) · desired \(status.desired) · cap \(status.capacityCap)"
        if status.jobCapacity > 0 { line += " · \(status.jobCapacity) job slots" }
        // A deliberate pause (e.g. a pause-first VM delete) must not read as
        // stuck: when the policy is on, the fleet will release itself.
        if status.paused, status.autoResume == true {
            line += "\n  ⏳ auto-resume: \(status.autoResumeCadence ?? "releases when the queue is empty")"
        }
        if let age = queueAge(status) { line += "\n  ⏱ queue age: \(age)" }
        if let byRepo = status.queueByRepo, status.queueDepth > 0, !byRepo.isEmpty {
            line += "\n  ↳ \(repoBreakdown(byRepo, limit: 2))"
        }
        if let byRepo = status.runningByRepo, status.activeCount > 0, !byRepo.isEmpty {
            line += "\n  ▶ \(repoBreakdown(byRepo, limit: 2))"
        }
        return line
    }

    // MARK: - Report (CLI)

    /// The multi-line `kinhin status` report, VMs included.
    public static func report(_ status: FleetStatus, now: Date = Date()) -> String {
        var lines: [String] = []
        lines.append("engine:    \(state(status))")
        if status.paused, status.autoResume == true {
            let release = status.autoResumeCadence ?? "the fleet releases itself when the queue is empty"
            lines.append("auto-resume: on — \(release)")
        }
        if let age = queueAge(status) { lines.append("queue age:  \(age)") }
        lines.append(
            "repo:      (see config)   queue: \(status.queueDepth)   desired: \(status.desired)   capacity cap: \(status.capacityCap)"
        )
        lines.append("job slots: \(status.jobCapacity) concurrent jobs (VM cap × runners_per_vm)")
        if let byRepo = status.queueByRepo, status.queueDepth > 0 || byRepo.count > 1, !byRepo.isEmpty {
            lines.append("queue by repo: \(repoBreakdown(byRepo))")
        }
        if let byRepo = status.runningByRepo, status.activeCount > 0, !byRepo.isEmpty {
            lines.append("running by repo: \(repoBreakdown(byRepo))")
        }
        if let err = status.lastError {
            lines.append("last error: \(err)")
        }
        if status.records.isEmpty {
            lines.append("no VMs")
        } else {
            lines.append("VMs:")
            for record in status.records {
                var line = "  \(record.id)  \(record.phase.rawValue)"
                if let platform = record.platform, platform != "github" { line += " [\(platform)]" }
                if let ip = record.ip { line += "  ip=\(ip)" }
                line += "  up=\(Int(now.timeIntervalSince(record.createdAt)))s"
                if let job = record.job { line += "  job=\(job)" }
                if let repos = record.repos, !repos.isEmpty { line += "  repos=\(repos.joined(separator: ","))" }
                if let err = record.error { line += "  error=\(err.prefix(120))" }
                lines.append(line)
            }
        }
        return lines.joined(separator: "\n")
    }
}
