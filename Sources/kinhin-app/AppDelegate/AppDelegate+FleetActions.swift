import AppKit
import KinhinKit

// Menu actions that drive the fleet (in-process engine or background daemon).

@MainActor
extension AppDelegate {
    // MARK: - Actions

    @objc func startFleet() {
        fleet.userStart { [weak self] in self?.openSetupTab() }
    }

    @objc func stopFleet() {
        fleet.userStop()
    }

    @objc func pauseFleet() {
        fleet.userSetPaused(true)
    }

    @objc func resumeFleet() {
        fleet.userSetPaused(false)
    }

    /// The menu's single Pause/Resume item: pauses a running fleet, resumes a paused one.
    @objc func togglePauseFleet() {
        fleet.userSetPaused(!(fleet.status?.paused ?? false))
    }

    @objc func deleteVM(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String else { return }
        deleteVM(id: id)
    }

    func deleteVM(id: String) {
        fleet.userDeleteVM(id: id)
    }
}
