import AppKit
import KinhinKit

// Menu actions that drive the fleet (in-process engine or background daemon).

@MainActor
extension AppDelegate {
    // MARK: Actions

    /// Sends a command to the background daemon and tells the user when it
    /// fails (daemon not running, or it rejected the request) instead of
    /// letting the menu action look like it worked.
    func sendDaemonCommand(_ method: RPCMethod, payload: Data? = nil, failureTitle: String) {
        do {
            try client?.command(method, payload: payload)
        } catch {
            AlertKit.present(error: error, title: failureTitle)
        }
    }

    @objc func startFleet() {
        Task {
            defer {
                pendingFleetAction = nil
                mainController?.fleetModel.endPendingAction()
            }
            pendingFleetAction = .start
            if let engine {
                await engine.start()
            } else if client != nil {
                sendDaemonCommand(.start, failureTitle: "Couldn't start the fleet")
            } else {
                openSetupTab()
            }
            await refresh()
        }
    }

    @objc func stopFleet() {
        Task {
            defer {
                pendingFleetAction = nil
                mainController?.fleetModel.endPendingAction()
            }
            pendingFleetAction = .stop
            if let engine {
                await engine.stop()
            } else if client != nil {
                sendDaemonCommand(.stop, failureTitle: "Couldn't stop the fleet")
            }
            await refresh()
        }
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
            if let engine {
                await engine.deleteVM(id: id)
            } else if client != nil {
                do {
                    let payload = try JSONEncoder().encode(Daemon.VMDeleteRequest(id: id))
                    sendDaemonCommand(.deleteVM, payload: payload, failureTitle: "Couldn't delete \(id)")
                } catch {
                    AlertKit.present(error: error, title: "Couldn't delete \(id)")
                }
            }
            await refresh()
        }
    }

    /// Runs a confirmation alert; overridable in tests via `confirmOverride`.
    func confirmDestructive(title: String, message: String, button: String) -> Bool {
        if let confirmOverride { return confirmOverride }
        return AlertKit.confirm(title: title, message: message, confirmTitle: button, destructive: true)
    }
}
