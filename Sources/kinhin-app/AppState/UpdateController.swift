import AppKit
import KinhinKit
import Observation

/// What `UpdateController` needs from the updater; `UpdateChecker` is the
/// production conformance, tests substitute a fake (no network).
protocol UpdateChecking: Sendable {
    func check() async throws -> UpdateCheckResult
    func downloadDMG(_ info: UpdateInfo, progress: (@Sendable (Double) -> Void)?) async throws -> URL
}

extension UpdateChecker: UpdateChecking {}

/// Update checking and download state: what the Settings → App update card
/// shows and whether the status-bar menu offers a newer release. The app
/// delegate re-renders the menu from this object; the card binds to it.
@MainActor
@Observable
final class UpdateController {
    /// Drives the Settings → App update card.
    var updateCardState: UpdateCardState
    var pendingUpdate: UpdateInfo?
    private(set) var lastUpdateCheck: Date?

    @ObservationIgnored private var checkTask: Task<Void, Never>?
    @ObservationIgnored private var downloadTask: Task<Void, Never>?
    @ObservationIgnored private var scheduleTask: Task<Void, Never>?
    @ObservationIgnored var makeChecker: () -> any UpdateChecking = { UpdateChecker(repo: UpdatePreferences.repo) }
    /// Where the 24h throttle stamp lives (tests inject a scratch suite).
    @ObservationIgnored let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        updateCardState = .idle(lastChecked: UpdatePreferences.lastCheck(in: defaults))
    }
    @ObservationIgnored var open: (URL) -> Bool = { NSWorkspace.shared.open($0) }

    // MARK: - Scheduling

    /// Checks at launch (at most once a day), then hourly (same throttle).
    func startScheduledChecks() {
        guard scheduleTask == nil else { return }
        if Date().timeIntervalSince(UpdatePreferences.lastCheck(in: defaults)) >= UpdatePreferences.interval {
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
            UpdatePreferences.setLastCheck(now, in: defaults)
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
            let url = try await makeChecker().downloadDMG(info, progress: nil)
            Log.info("app", "update downloaded to \(url.path)")
            guard open(url) else {
                Log.error("app", "could not open the downloaded update at \(url.path)")
                updateCardState = .failed("Downloaded the update but couldn't open it — find it at \(url.path)")
                return
            }
            updateCardState = .available(version: info.version)
        } catch is CancellationError {
            updateCardState = .available(version: info.version)
        } catch {
            Log.error("app", "update download failed: \(error.localizedDescription)")
            updateCardState = .failed(error.localizedDescription)
        }
    }
}
