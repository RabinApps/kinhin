import KinhinKit

// The user-facing fleet actions shared by every UI entry point (status-bar
// menu, Fleet tab buttons): pending-state bookkeeping plus the failure alert.
// App Intents use the throwing `perform`/`setPaused`/`deleteVM` directly,
// since Shortcuts reports errors itself.
@MainActor
extension FleetController {
    /// Starts the fleet. With nothing configured yet, Setup is the answer,
    /// not an alert (`openSetup`).
    func userStart(openSetup: @escaping () -> Void) {
        guard service != nil else {
            openSetup()
            return
        }
        run(
            .start,
            failureTitle: String(
                localized: "Couldn't start the fleet", bundle: .l10n,
                comment: "Alert title when starting the fleet fails"))
    }

    func userStop() {
        run(
            .stop,
            failureTitle: String(
                localized: "Couldn't stop the fleet", bundle: .l10n,
                comment: "Alert title when stopping the fleet fails"))
    }

    func userRequeueQueuedJobs(for forge: ForgeID) {
        guard pendingFleetAction == nil else { return }  // a command is already running
        pendingFleetAction = .requeueQueuedJobs(for: forge)
        Task { @MainActor in
            do {
                try await requeueQueuedJobs(for: forge)
            } catch {
                AlertKit.present(
                    error: error,
                    title: String(
                        localized: "Couldn't requeue the queued jobs", bundle: .l10n,
                        comment: "Alert title when requeueing queued jobs fails"))
            }
            pendingFleetAction = nil
        }
    }

    func userSkipQueuedJobs(for forge: ForgeID) {
        guard pendingFleetAction == nil else { return }  // a command is already running
        pendingFleetAction = .skipQueuedJobs(for: forge)
        Task { @MainActor in
            do {
                try await skipQueuedJobs(for: forge)
            } catch {
                AlertKit.present(
                    error: error,
                    title: String(
                        localized: "Couldn't skip the queued jobs", bundle: .l10n,
                        comment: "Alert title when skipping queued jobs fails"))
            }
            pendingFleetAction = nil
        }
    }

    func userSetPaused(_ paused: Bool) {
        let title =
            paused
            ? String(localized: "Couldn't pause the fleet", bundle: .l10n, comment: "Alert title when pausing fails")
            : String(localized: "Couldn't resume the fleet", bundle: .l10n, comment: "Alert title when resuming fails")
        Task {
            do {
                try await setPaused(paused)
            } catch {
                AlertKit.present(error: error, title: title)
            }
        }
    }

    /// Confirms, then deletes the VM.
    func userDeleteVM(id: String) {
        guard
            AlertKit.confirm(
                title: String(localized: "Delete \(id)?", bundle: .l10n, comment: "Confirmation title; %@ is a VM id"),
                message: String(
                    localized: "This stops the VM and removes it. Any job running on it is cancelled.", bundle: .l10n,
                    comment: "Confirmation body for deleting a VM"),
                confirmTitle: String(localized: "Delete", bundle: .l10n, comment: "Destructive confirm button"),
                destructive: true)
        else { return }
        Task {
            do {
                try await deleteVM(id: id)
            } catch {
                AlertKit.present(
                    error: error,
                    title: String(
                        localized: "Couldn't delete \(id)", bundle: .l10n,
                        comment: "Alert title when deleting a VM fails; %@ is a VM id"))
            }
        }
    }

    /// Approves a healing fix (the button is the approval: no second prompt).
    /// The returned task ends once the backend answered and the status refreshed.
    @discardableResult
    func userApproveHealing(id: String) -> Task<Void, Never> {
        Task {
            do {
                try await approveHealing(id: id)
            } catch {
                AlertKit.present(
                    error: error,
                    title: String(
                        localized: "Couldn't approve fix \(id)", bundle: .l10n,
                        comment: "Alert title when approving a healing fix fails; %@ is the fix id (h-…)"))
            }
        }
    }

    /// Dismisses a pending fix or a surfaced problem.
    @discardableResult
    func userDismissHealing(id: String) -> Task<Void, Never> {
        Task {
            do {
                try await dismissHealing(id: id)
            } catch {
                AlertKit.present(
                    error: error,
                    title: String(
                        localized: "Couldn't dismiss \(id)", bundle: .l10n,
                        comment: "Alert title when dismissing a healing event fails; %@ is the event id (h-…)"))
            }
        }
    }

    /// The pending flag is set before the task starts, so a second click in
    /// the same tick already reads as busy.
    private func run(_ action: FleetAction, failureTitle: String) {
        guard pendingFleetAction == nil else { return }  // a command is already running
        pendingFleetAction = action
        Task {
            do {
                try await perform(action)
            } catch {
                AlertKit.present(error: error, title: failureTitle)
            }
        }
    }
}
