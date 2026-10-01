import AppKit
import KinhinKit
import Observation

/// Update checking and download state: what the Settings → App update card
/// shows and whether the status-bar menu offers a newer release. The app
/// delegate re-renders the menu from this object; the card binds to it.
@MainActor
@Observable
final class UpdateController {
    /// Drives the Settings → App update card.
    var updateCardState: UpdateCardState = .idle(lastChecked: UpdatePreferences.lastCheck)
    var pendingUpdate: UpdateInfo?
    private(set) var lastUpdateCheck: Date?

    @ObservationIgnored private var checkTask: Task<Void, Never>?
    @ObservationIgnored private var downloadTask: Task<Void, Never>?
    @ObservationIgnored private var scheduleTask: Task<Void, Never>?
    @ObservationIgnored var makeChecker: () -> UpdateChecker = { UpdateChecker(repo: UpdatePreferences.repo) }
    @ObservationIgnored var open: (URL) -> Void = { NSWorkspace.shared.open($0) }

    // MARK: - Scheduling

    /// Checks at launch (at most once a day), then hourly (same throttle).
    func startScheduledChecks() {
        guard scheduleTask == nil else { return }
        if Date().timeIntervalSince(UpdatePreferences.lastCheck) >= UpdatePreferences.interval {
            checkForUpdates()
        }
        scheduleTask = Task { [weak self] in
            while !Task.isCancelled {
                do {
                    try await Task.sleep(for: .seconds(3600))
                } catch {
                    return
                }
                self?.checkForUpdates()
            }
        }
    }

    func cancelAll() {
        scheduleTask?.cancel()
        checkTask?.cancel()
        downloadTask?.cancel()
        scheduleTask = nil
    }

    // MARK: - Checking

    func checkForUpdates() {
        guard checkTask == nil else { return }  // one at a time
        updateCardState = .checking
        checkTask = Task { [weak self] in
            await self?.runCheck()
        }
    }

    /// The card/menu button: download when a release is waiting, otherwise check.
    func checkOrDownload() {
        guard let info = pendingUpdate else {
            checkForUpdates()
            return
        }
        // Download the release DMG (checksum- and signature-verified by the
        // updater) and open it so the user lands in Finder, ready to install.
        guard downloadTask == nil else { return }
        downloadTask = Task { [weak self] in
            await self?.downloadAndPresent(info)
        }
    }

    private func runCheck() async {
        defer { checkTask = nil }
        do {
            let result = try await makeChecker().check()
            let now = Date()
            lastUpdateCheck = now
            UpdatePreferences.lastCheck = now
            switch result {
            case .upToDate:
                updateCardState = .upToDate(lastChecked: now)
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
                updateCardState = .available(version: info.version)
            }
        } catch is CancellationError {
            // shutting down or superseded; stay quiet
            updateCardState = .idle(lastChecked: lastUpdateCheck)
        } catch {
            Log.info("app", "update check skipped: \(error.localizedDescription)")
            updateCardState = .failed(error.localizedDescription)
        }
    }

    private func downloadAndPresent(_ info: UpdateInfo) async {
        defer { downloadTask = nil }
        do {
            updateCardState = .downloading(name: info.dmgName)
            let url = try await makeChecker().downloadDMG(info)
            Log.info("app", "update downloaded to \(url.path)")
            open(url)
            updateCardState = .available(version: info.version)
        } catch is CancellationError {
            updateCardState = .available(version: info.version)
        } catch {
            Log.error("app", "update download failed: \(error.localizedDescription)")
            updateCardState = .failed(error.localizedDescription)
        }
    }
}
