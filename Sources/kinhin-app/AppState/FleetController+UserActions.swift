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
        run(.start, failureTitle: "Couldn't start the fleet")
    }

    func userStop() {
        run(.stop, failureTitle: "Couldn't stop the fleet")
    }

    func userSetPaused(_ paused: Bool) {
        let title = paused ? "Couldn't pause the fleet" : "Couldn't resume the fleet"
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
                title: "Delete \(id)?",
                message: "This stops the VM and removes it. Any job running on it is cancelled.",
                confirmTitle: "Delete", destructive: true)
        else { return }
        Task {
            do {
                try await deleteVM(id: id)
            } catch {
                AlertKit.present(error: error, title: "Couldn't delete \(id)")
            }
        }
    }

    /// The pending flag is set before the task starts, so a second click in
    /// the same tick already reads as busy.
    private func run(_ action: FleetAction, failureTitle: String) {
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
