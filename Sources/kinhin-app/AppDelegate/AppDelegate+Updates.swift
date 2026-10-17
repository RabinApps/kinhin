import AppKit
import KinhinKit

@MainActor
extension AppDelegate {
    // MARK: - Update menu items

    /// Syncs the status-bar update items with `UpdateController`: the
    /// "Update available" item only shows while Sparkle has found a newer
    /// release that is not installed yet. Internal so tests can drive it
    /// against a built menu.
    func refreshUpdateItems() {
        let pending = updates.pendingVersion
        guard let menu else { return }
        guard let idx = menu.items.firstIndex(where: { $0.identifier?.rawValue == "updateItem" }),
            menu.items.indices.contains(idx + 1)
        else { return }
        if let version = pending {
            menu.items[idx].title = String(
                localized: "Update available — kinhin \(version)…", bundle: .l10n,
                comment: "Status-bar menu item when a newer release is waiting; %@ is the version")
            menu.items[idx].isEnabled = true
            menu.items[idx].isHidden = false
            menu.items[idx + 1].title = String(
                localized: "  kinhin \(kinhinVersion.current) (up to date)", bundle: .l10n,
                comment: "Disabled version row in the status-bar menu while an update is pending; %@ is the version")
        } else {
            menu.items[idx].isHidden = true
            menu.items[idx + 1].title = String(
                localized: "  kinhin \(kinhinVersion.current)", bundle: .l10n,
                comment: "Disabled version row in the status-bar menu; %@ is the version")
        }
        menu.items[idx + 1].isEnabled = false
    }

    /// Opens Sparkle's update prompt for the waiting release (or checks now).
    @objc func updateItemClicked() {
        updates.checkForUpdates()
    }
}
