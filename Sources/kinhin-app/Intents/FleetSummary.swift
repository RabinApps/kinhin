import KinhinKit

/// Spoken one-liners for the App Intents. Pure so they can be tested
/// without AppIntents. None of these include tokens or other secrets.
///
/// Every sentence is localized whole (never spliced from fragments), so a translation can reorder
/// freely.
enum FleetSummary {
    static func status(_ status: FleetStatus) -> String {
        guard status.running else {
            return String(localized: "The fleet is stopped.", bundle: .l10n, comment: "Spoken fleet status")
        }
        var parts = [
            status.paused
                ? String(localized: "The fleet is paused.", bundle: .l10n, comment: "Spoken fleet status")
                : String(localized: "The fleet is running.", bundle: .l10n, comment: "Spoken fleet status")
        ]
        if status.paused, status.autoResume == true {
            parts.append(
                status.autoResumeCadence.map {
                    String(
                        localized: "Auto-resume is on — it \($0).", bundle: .l10n,
                        comment: "Spoken fleet status; %@ is a clause describing the auto-resume cadence")
                }
                    ?? String(
                        localized: "Auto-resume is on — it will release the fleet when the queue is empty.",
                        bundle: .l10n, comment: "Spoken fleet status"))
        }
        parts.append(
            String(
                localized: "\(status.activeCount) of \(status.capacityCap) VMs active.", bundle: .l10n,
                comment: "Spoken fleet status; first number is the active VMs, second is the capacity"))
        parts.append(
            String(
                localized: "\(status.queueDepth) jobs queued.", bundle: .l10n,
                comment: "Spoken fleet status; plural by queued job count"))
        if let error = status.lastError, !error.isEmpty {
            parts.append(
                String(
                    localized: "Last error: \(error)", bundle: .l10n,
                    comment: "Spoken fleet status; %@ is the engine's error message"))
        }
        return parts.joined(separator: " ")
    }

    /// Outcome of a pause/resume request given the state before it ran.
    static func pauseResult(paused: Bool, before: FleetStatus) -> String {
        guard before.running else {
            return paused
                ? String(
                    localized: "The fleet isn't running, so there is nothing to pause.", bundle: .l10n,
                    comment: "Spoken reply to a pause request")
                : String(
                    localized: "The fleet isn't running, so there is nothing to resume.", bundle: .l10n,
                    comment: "Spoken reply to a resume request")
        }
        if before.paused == paused {
            return paused
                ? String(
                    localized: "The fleet is already paused.", bundle: .l10n,
                    comment: "Spoken reply to a pause request")
                : String(
                    localized: "The fleet isn't paused.", bundle: .l10n, comment: "Spoken reply to a resume request")
        }
        return paused
            ? String(
                localized: "Paused. Running jobs finish, but no new VMs will start.", bundle: .l10n,
                comment: "Spoken reply to a pause request")
            : String(localized: "Resumed.", bundle: .l10n, comment: "Spoken reply to a resume request")
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
        switch outcome {
        case .alreadyThere:
            return start
                ? String(
                    localized: "The fleet is already running.", bundle: .l10n,
                    comment: "Spoken reply to a start request")
                : String(
                    localized: "The fleet is already stopped.", bundle: .l10n,
                    comment: "Spoken reply to a stop request")
        case .done:
            return start
                ? String(
                    localized: "Started. Queued jobs can begin.", bundle: .l10n,
                    comment: "Spoken reply to a start request")
                : String(
                    localized: "Stopped. No new VMs will start.", bundle: .l10n,
                    comment: "Spoken reply to a stop request")
        case .uncertain:
            return start
                ? String(
                    localized: "The start is in progress — check the fleet status in a moment.", bundle: .l10n,
                    comment: "Spoken reply to a start request")
                : String(
                    localized: "The stop is in progress — check the fleet status in a moment.", bundle: .l10n,
                    comment: "Spoken reply to a stop request")
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

    static func deleteResult(
        id: String, outcome: DeleteOutcome, pausedFirst: Bool = false, autoResume: Bool? = nil
    ) -> String {
        switch outcome {
        case .notFound:
            return noVMNamed(id)
        case .deleted:
            guard pausedFirst else {
                return String(
                    localized: "Deleted VM \(id).", bundle: .l10n,
                    comment: "Spoken reply to a delete request; %@ is a VM id")
            }
            // Autoscale would otherwise recreate the VM within one poll —
            // say which way the pause lets go, since the two policies read
            // very differently in the UI.
            return autoResume == true
                ? String(
                    localized:
                        "Deleted VM \(id). The fleet is paused; auto-resume will release it when the queue is empty.",
                    bundle: .l10n, comment: "Spoken reply to a delete request; %@ is a VM id")
                : String(
                    localized: "Deleted VM \(id). The fleet is paused, so it won't be recreated until you resume.",
                    bundle: .l10n, comment: "Spoken reply to a delete request; %@ is a VM id")
        case .uncertain:
            return String(
                localized: "Deleting \(id) is in progress — check the fleet status in a moment.", bundle: .l10n,
                comment: "Spoken reply to a delete request; %@ is a VM id")
        }
    }

    /// Spoken diagnosis of one VM: phase, assigned job, last error — what a
    /// user needs before deciding to delete a stalled VM.
    static func diagnose(id: String, record: VMRecord?) -> String {
        guard let record else { return noVMNamed(id) }
        var parts = [phaseSentence(id: id, phase: record.phase)]
        if let job = record.job, !job.isEmpty {
            parts.append(
                record.phase == .busy
                    ? String(
                        localized: "It is working on job \(job).", bundle: .l10n,
                        comment: "Spoken VM diagnosis; %@ is a job name")
                    : String(
                        localized: "Its last job was \(job).", bundle: .l10n,
                        comment: "Spoken VM diagnosis; %@ is a job name"))
        }
        if let error = record.error, !error.isEmpty {
            parts.append(
                String(
                    localized: "Last error: \(error).", bundle: .l10n,
                    comment: "Spoken VM diagnosis; %@ is the error message"))
        }
        return parts.joined(separator: " ")
    }

    /// One whole sentence per phase (not a phrase spliced into a template), so each reads
    /// naturally in any language.
    private static func phaseSentence(id: String, phase: VMPhase) -> String {
        switch phase {
        case .cloning:
            return String(
                localized: "VM \(id) is still cloning.", bundle: .l10n, comment: "Spoken VM diagnosis; %@ is a VM id")
        case .booting:
            return String(
                localized: "VM \(id) is booting.", bundle: .l10n, comment: "Spoken VM diagnosis; %@ is a VM id")
        case .registering:
            return String(
                localized: "VM \(id) is registering.", bundle: .l10n, comment: "Spoken VM diagnosis; %@ is a VM id")
        case .ready:
            return String(
                localized: "VM \(id) is ready and waiting for a job.", bundle: .l10n,
                comment: "Spoken VM diagnosis; %@ is a VM id")
        case .busy:
            return String(
                localized: "VM \(id) is running a job.", bundle: .l10n, comment: "Spoken VM diagnosis; %@ is a VM id")
        case .deleting:
            return String(
                localized: "VM \(id) is being deleted.", bundle: .l10n, comment: "Spoken VM diagnosis; %@ is a VM id")
        case .failed:
            return String(
                localized: "VM \(id) failed.", bundle: .l10n, comment: "Spoken VM diagnosis; %@ is a VM id")
        }
    }

    private static func noVMNamed(_ id: String) -> String {
        String(
            localized: "No VM named \(id) is in the fleet.", bundle: .l10n,
            comment: "Spoken reply when a VM id is unknown; %@ is the id")
    }

    /// Outcome of an auto-resume policy toggle.
    enum AutoResumeOutcome {
        /// The policy was already in the wanted state — nothing was written.
        case alreadyThere
        /// The config was written and the change pushed to the engine.
        case done
    }

    static func autoResumeResult(on: Bool, outcome: AutoResumeOutcome) -> String {
        switch outcome {
        case .alreadyThere:
            return on
                ? String(
                    localized: "Auto-resume is already on.", bundle: .l10n,
                    comment: "Spoken reply to an auto-resume request")
                : String(
                    localized: "Auto-resume is already off.", bundle: .l10n,
                    comment: "Spoken reply to an auto-resume request")
        case .done:
            return on
                ? String(
                    localized: "Auto-resume is on. A paused fleet releases itself once the queue is empty.",
                    bundle: .l10n, comment: "Spoken reply to an auto-resume request")
                : String(
                    localized: "Auto-resume is off. A pause holds until you resume the fleet.", bundle: .l10n,
                    comment: "Spoken reply to an auto-resume request")
        }
    }

    static func doctor(_ report: DoctorReport) -> String {
        doctor(ready: report.ready, checks: report.checks)
    }

    static func doctor(ready: Bool, checks: [SetupCheckResult]) -> String {
        if ready {
            return String(localized: "Everything looks good.", bundle: .l10n, comment: "Spoken diagnostics result")
        }
        let failures = checks.filter { !$0.ok }
        guard let first = failures.first else {
            return String(
                localized: "kinhin isn't fully ready. Open Diagnostics for details.", bundle: .l10n,
                comment: "Spoken diagnostics result")
        }
        if failures.count > 1 {
            return String(
                localized: "\(first.title): \(first.detail) (and \(failures.count - 1) more)", bundle: .l10n,
                comment:
                    "Spoken diagnostics result; the first two values come from a setup check, the number counts further failing checks"
            )
        }
        return String(
            localized: "\(first.title): \(first.detail)", bundle: .l10n,
            comment: "Spoken diagnostics result; both values come from a setup check")
    }
}
