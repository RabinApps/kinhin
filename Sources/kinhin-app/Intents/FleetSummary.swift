import KinhinKit

/// Spoken one-liners for the App Intents. Pure so they can be tested
/// without AppIntents. None of these include tokens or other secrets.
enum FleetSummary {
    static func status(_ status: FleetStatus) -> String {
        guard status.running else { return "The fleet is stopped." }
        var parts = [status.paused ? "The fleet is paused." : "The fleet is running."]
        parts.append("\(status.activeCount) of \(status.capacityCap) VMs active.")
        parts.append(status.queueDepth == 1 ? "1 job queued." : "\(status.queueDepth) jobs queued.")
        if let error = status.lastError, !error.isEmpty {
            parts.append("Last error: \(error)")
        }
        return parts.joined(separator: " ")
    }

    /// Outcome of a pause/resume request given the state before it ran.
    static func pauseResult(paused: Bool, before: FleetStatus) -> String {
        guard before.running else {
            return "The fleet isn't running, so there is nothing to \(paused ? "pause" : "resume")."
        }
        if before.paused == paused { return paused ? "The fleet was already paused." : "The fleet wasn't paused." }
        return paused ? "Paused. Running jobs finish, but no new VMs will start." : "Resumed."
    }

    static func doctor(_ report: DoctorReport) -> String {
        doctor(ready: report.ready, checks: report.checks)
    }

    static func doctor(ready: Bool, checks: [SetupCheckResult]) -> String {
        if ready { return "Everything looks good." }
        let failures = checks.filter { !$0.ok }
        guard let first = failures.first else { return "kinhin isn't fully ready. Open Diagnostics for details." }
        let more = failures.count > 1 ? " (and \(failures.count - 1) more)" : ""
        return "\(first.title): \(first.detail)\(more)"
    }
}
