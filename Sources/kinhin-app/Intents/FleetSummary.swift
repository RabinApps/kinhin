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

    /// Outcome of a start/stop request.
    enum StartStopOutcome {
        /// The fleet was already in the wanted state — nothing ran.
        case alreadyThere
        /// The command ran and the status poll confirms the wanted state.
        case done
        /// The command ran but the follow-up poll disagrees (or failed):
        /// the engine may still be mid-transition (forge verification on
        /// start, draining VMs on stop).
        case uncertain
    }

    static func startStopResult(start: Bool, outcome: StartStopOutcome) -> String {
        let action = start ? "start" : "stop"
        switch outcome {
        case .alreadyThere:
            return start ? "The fleet is already running." : "The fleet is already stopped."
        case .done:
            return start ? "Started. Queued jobs can begin." : "Stopped. No new VMs will start."
        case .uncertain:
            return "The \(action) is in progress — check the fleet status in a moment."
        }
    }

    /// Outcome of a delete request for one VM.
    enum DeleteOutcome {
        /// No record with that id — nothing ran.
        case notFound
        /// The command ran and the follow-up poll no longer lists the VM.
        case deleted
        /// The command ran but the poll still lists the VM (teardown is
        /// async).
        case uncertain
    }

    static func deleteResult(id: String, outcome: DeleteOutcome) -> String {
        switch outcome {
        case .notFound:
            return "No VM named \(id) is in the fleet."
        case .deleted:
            return "Deleted VM \(id)."
        case .uncertain:
            return "Deleting \(id) is in progress — check the fleet status in a moment."
        }
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
