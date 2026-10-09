import AppKit
import KinhinKit

@MainActor
extension AppDelegate {
    // MARK: - Update menu items

    /// Syncs the status-bar update items with `UpdateController`: the
    /// "Update available" item only shows while a newer release is waiting
    /// (and reads "Downloading…" while it downloads). Internal so tests can
    /// drive it against a built menu.
    func refreshUpdateItems() {
        let pending = updates.pendingUpdate
        let card = updates.updateCardState
        guard let menu else { return }
        guard let idx = menu.items.firstIndex(where: { $0.identifier?.rawValue == "updateItem" }),
            menu.items.indices.contains(idx + 1)
        else { return }
        if case .downloading(let name) = card {
            menu.items[idx].title = String(
                localized: "Downloading \(name)…", bundle: .l10n,
                comment: "Status-bar menu item while an update downloads; %@ is the DMG file name")
            menu.items[idx].isEnabled = false
            menu.items[idx].isHidden = false
            menu.items[idx + 1].title = String(
                localized: "  kinhin \(kinhinVersion.current) (up to date)", bundle: .l10n,
                comment: "Disabled version row in the status-bar menu while an update is pending; %@ is the version")
        } else if let info = pending {
            menu.items[idx].title = String(
                localized: "Update available — kinhin \(info.version)…", bundle: .l10n,
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

    @objc func updateItemClicked() {
        updates.checkOrDownload()
    }
}
