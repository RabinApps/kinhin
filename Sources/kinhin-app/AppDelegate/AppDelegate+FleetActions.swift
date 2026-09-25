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
            if let engine {
                await engine.stop()
            } else if client != nil {
                sendDaemonCommand(.stop, failureTitle: "Couldn't stop the fleet")
            }
            await refresh()
        }
    }

    @objc func pauseFleet() {
        Task {
            if let engine {
                await engine.setPaused(true)
            } else if client != nil {
                sendDaemonCommand(.pause, failureTitle: "Couldn't pause the fleet")
            }
            await refresh()
        }
    }

    @objc func resumeFleet() {
        Task {
            if let engine {
                await engine.setPaused(false)
            } else if client != nil {
                sendDaemonCommand(.resume, failureTitle: "Couldn't resume the fleet")
            }
            await refresh()
        }
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
