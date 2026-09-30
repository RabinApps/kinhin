import AppKit
import KinhinKit

// Menu actions that drive the fleet (in-process engine or background daemon).

@MainActor
extension AppDelegate {
    // MARK: Actions

    @objc func startFleet() {
        Task {
            // Nothing configured yet: Setup is the answer, not an alert.
            guard engine != nil || client != nil else { openSetupTab(); return }
            do {
                try await performFleetAction(.start)
            } catch {
                AlertKit.present(error: error, title: "Couldn't start the fleet")
            }
        }
    }

    @objc func stopFleet() {
        Task {
            do {
                try await performFleetAction(.stop)
            } catch {
                AlertKit.present(error: error, title: "Couldn't stop the fleet")
            }
        }
    }

    /// Runs a start/stop with the pending-state bookkeeping shared by every
    /// entry point (menu item, Fleet tab button, App Intent). Throws when no
    /// backend is available — the @objc wrappers surface that per their own
    /// UX, and intents propagate it into the Shortcuts dialog.
    func performFleetAction(_ action: PendingFleetAction) async throws {
        defer {
            pendingFleetAction = nil
            mainController?.fleetModel.endPendingAction()
        }
        pendingFleetAction = action
        if let engine {
            if action == .start { await engine.start() } else { await engine.stop() }
        } else if let client {
            // Throw, don't alert: the menu wrappers alert, and an App Intent
            // must fail in Shortcuts rather than report success.
            try client.command(action == .start ? .start : .stop)
        } else {
            throw FleetAccessError.notSetUp
        }
        await refresh()
    }

    @objc func pauseFleet() {
        setPausedFromMenu(true, failureTitle: "Couldn't pause the fleet")
    }

    @objc func resumeFleet() {
        setPausedFromMenu(false, failureTitle: "Couldn't resume the fleet")
    }

    private func setPausedFromMenu(_ paused: Bool, failureTitle: String) {
        Task {
            do {
                try await setFleetPaused(paused)
            } catch {
                AlertKit.present(error: error, title: failureTitle)
            }
            await refresh()
        }
    }

    // MARK: Throwing fleet access (menu actions and App Intents)

    /// Pauses or resumes the fleet through whichever backend is live.
    /// Throws when there is none (setup incomplete) or the daemon fails.
    func setFleetPaused(_ paused: Bool) async throws {
        if let engine {
            await engine.setPaused(paused)
        } else if let client {
            try client.command(paused ? .pause : .resume)
        } else {
            throw FleetAccessError.notSetUp
        }
    }

    /// Current fleet status from the in-process engine or the daemon.
    func fleetStatus() async throws -> FleetStatus {
        if let engine {
            return await engine.status()
        }
        guard let client else { throw FleetAccessError.notSetUp }
        let response = try client.send(method: .status)
        guard response.ok, let payload = response.payload else {
            throw RPCError.rejected(response.error ?? "no status payload")
        }
        return try JSONDecoder().decode(FleetStatus.self, from: payload)
    }

    @objc func deleteVM(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String else { return }
        deleteVM(id: id)
    }

    func deleteVM(id: String) {
        guard
            confirmDestructive(
                title: "Delete \(id)?",
                message: "This stops the VM and removes it. Any job running on it is cancelled.",
                button: "Delete")
        else { return }
        Task {
            do {
                try await performVMDelete(id: id)
            } catch {
                AlertKit.present(error: error, title: "Couldn't delete \(id)")
            }
        }
    }

    /// Runs the delete through whichever backend is live, without asking
    /// first. Entry points confirm in their own UX (menu shows NSAlert; the
    /// App Intent relies on Shortcuts' explicit pick and its confirm toggle,
    /// since intents can't present alerts). Throws when no backend is set up
    /// — the menu path alerts, the intent path lands in the dialog.
    func performVMDelete(id: String) async throws {
        if let engine {
            await engine.deleteVM(id: id)
        } else if let client {
            let payload = try JSONEncoder().encode(Daemon.VMDeleteRequest(id: id))
            try client.command(.deleteVM, payload: payload)
        } else {
            throw FleetAccessError.notSetUp
        }
        await refresh()
    }

    /// Runs a confirmation alert; overridable in tests via `confirmOverride`.
    func confirmDestructive(title: String, message: String, button: String) -> Bool {
        if let confirmOverride { return confirmOverride }
        return AlertKit.confirm(title: title, message: message, confirmTitle: button, destructive: true)
    }
}
