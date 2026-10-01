import AppKit
import KinhinKit

// Menu actions that drive the fleet (in-process engine or background daemon).

@MainActor
extension AppDelegate {
    // MARK: - Actions

    @objc func startFleet() {
        // Nothing configured yet: Setup is the answer, not an alert. The
        // Fleet tab's button already marked the action pending, so clear it.
        guard fleet.service != nil else {
            fleet.pendingFleetAction = nil
            openSetupTab()
            return
        }
        Task {
            do {
                try await fleet.perform(.start)
            } catch {
                AlertKit.present(error: error, title: "Couldn't start the fleet")
            }
        }
    }

    @objc func stopFleet() {
        Task {
            do {
                try await fleet.perform(.stop)
            } catch {
                AlertKit.present(error: error, title: "Couldn't stop the fleet")
            }
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
                try await fleet.setPaused(paused)
            } catch {
                AlertKit.present(error: error, title: failureTitle)
            }
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
            do {
                try await fleet.deleteVM(id: id)
            } catch {
                AlertKit.present(error: error, title: "Couldn't delete \(id)")
            }
        }
    }

    /// Runs a confirmation alert.
    func confirmDestructive(title: String, message: String, button: String) -> Bool {
        AlertKit.confirm(title: title, message: message, confirmTitle: button, destructive: true)
    }
}
