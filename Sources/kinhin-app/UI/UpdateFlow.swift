import AppKit
import KinhinKit

@MainActor
extension AppDelegate {
    // MARK: Update checking

    @objc func checkForUpdates() {
        guard updateCheckTask == nil else { return } // one at a time
        updateCheckTask = Task { [weak self] in
            await self?.runUpdateCheck()
        }
    }

    private func runUpdateCheck() async {
        defer { updateCheckTask = nil }
        do {
            let result = try await updateChecker.check()
            lastUpdateCheck = Date()
            UpdatePreferences.lastCheck = lastUpdateCheck ?? Date()
            switch result {
            case .upToDate:
                if pendingUpdate != nil {
                    Log.info("app", "update superseded; installed version is current again")
                }
                pendingUpdate = nil
                Log.info("app", "update check: up to date (v\(kinhinVersion.current))")
            case .available(let info):
                if pendingUpdate?.tag != info.tag {
                    Log.info("app", "update available: \(info.tag) (running v\(kinhinVersion.current))")
                }
                pendingUpdate = info
            }
            refreshUpdateItems()
        } catch is CancellationError {
            // shutting down or superseded; stay quiet
        } catch {
            Log.info("app", "update check skipped: \(error.localizedDescription)")
        }
    }

    /// Syncs the two update menu items with the current pending-update
    /// state. Internal so tests can drive it against a built menu.
    func refreshUpdateItems() {
        guard let menu else { return }
        guard let idx = menu.items.firstIndex(where: { $0.identifier?.rawValue == "updateItem" }),
              menu.items.indices.contains(idx + 1) else { return }
        if let info = pendingUpdate {
            menu.items[idx].title = "Update available — kinhin \(info.version)…"
            menu.items[idx].isEnabled = true
            menu.items[idx + 1].title = "  \("kinhin " + kinhinVersion.current) (up to date)"
            menu.items[idx + 1].isEnabled = false
        } else {
            menu.items[idx].title = "Check for Updates…"
            menu.items[idx].isEnabled = true
            menu.items[idx + 1].title = "  \("kinhin " + kinhinVersion.current)"
            menu.items[idx + 1].isEnabled = false
        }
    }

    @objc func updateItemClicked() {
        guard let info = pendingUpdate else {
            checkForUpdates()
            return
        }
        // Download the release DMG (never quarantined — no Gatekeeper prompts)
        // and open it so the user lands in Finder, ready to install.
        guard updateDownloadTask == nil else { return }
        updateDownloadTask = Task { [weak self] in
            await self?.downloadAndPresent(info)
        }
    }

    private func downloadAndPresent(_ info: UpdateInfo) async {
        defer { updateDownloadTask = nil }
        do {
            if let item = menu?.items.first(where: { $0.identifier?.rawValue == "updateItem" }) {
                item.title = "Downloading \(info.dmgName)…"
                item.isEnabled = false
            }
            let url = try await updateChecker.downloadDMG(info)
            Log.info("app", "update downloaded to \(url.path)")
            NSWorkspace.shared.open(url)
            if let item = menu?.items.first(where: { $0.identifier?.rawValue == "updateItem" }) {
                item.title = "Check for Updates…"
                item.isEnabled = true
            }
        } catch is CancellationError {
            refreshUpdateItems()
        } catch {
            Log.error("app", "update download failed: \(error.localizedDescription)")
            refreshUpdateItems()
        }
    }
}
