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

    /// "Host CPU 34% · RAM 21.0/64 GB". CPU is omitted until a second sample exists.
    public static func hostLine(_ host: HostUsage) -> String {
        var parts: [String] = []
        if let cpu = host.cpuPercent { parts.append("CPU \(Int(cpu.rounded()))%") }
        parts.append("RAM \(String(format: "%.1f", host.memoryUsedGB))/\(Int(host.memoryTotalGB.rounded())) GB")
        return "Host " + parts.joined(separator: " · ")
    }

    /// "CPU 120% · RAM 3.2/8 GB" for one VM or container; nil when nothing was measured.
    /// Container CPU is percent of one core, so it can exceed 100; a Tart VM's is percent of its cores.
    public static func usage(of record: VMRecord) -> String? {
        record.usage.flatMap(describe)
    }

    /// The same rendering for a bare `ResourceUsage` (the Containers tab).
    public static func describe(_ usage: ResourceUsage) -> String? {
        var parts: [String] = []
        if let cpu = usage.cpuPercent { parts.append("CPU \(Int(cpu.rounded()))%") }
        if let used = usage.memoryUsedMB {
            let usedGB = String(format: "%.1f", Double(used) / 1024)
            if let limit = usage.memoryLimitMB, limit > 0 {
                parts.append("RAM \(usedGB)/\(String(format: "%g", (Double(limit) / 1024 * 10).rounded() / 10)) GB")
            } else {
                parts.append("RAM \(usedGB) GB")
            }
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
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
        if let host = status.host { line += "\n  🖥 \(hostLine(host))" }
        if let note = rateLimitNote(status) { line += "\n  ⚠ \(note)" }
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
        if let host = status.host { lines.append("host:      \(hostLine(host).dropFirst(5))") }
        if let note = rateLimitNote(status) { lines.append("rate limit: \(note)") }
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
                if let usage = usage(of: record) { line += "  \(usage)" }
                if let err = record.error { line += "  error=\(err.prefix(120))" }
                lines.append(line)
            }
        }
        return lines.joined(separator: "\n")
    }

    /// Why polling is slower than configured, with when the forge budget comes back.
    static func rateLimitNote(_ status: FleetStatus, now: Date = Date()) -> String? {
        guard status.pollSlowdown != nil, let reset = status.rateLimitResetAt, reset > now else { return nil }
        let time = reset.formatted(date: .omitted, time: .shortened)
        return "forge API budget is running low; polling is slowed until it resets at \(time)"
    }
}
