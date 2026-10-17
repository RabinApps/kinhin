import KinhinKit
import Observation
import Sparkle

/// Self-update state for Settings → App and the status-bar menu. Sparkle does
/// the work: scheduled checks, the update prompt, EdDSA verification, the
/// in-place install and the relaunch. This object mirrors what Sparkle reports
/// so the card and the menu can say where things stand.
@MainActor
@Observable
final class UpdateController {
    /// Drives the Settings → App update card.
    var updateCardState: UpdateCardState
    /// The release Sparkle found and has not installed yet; the menu offers it.
    var pendingVersion: String?

    @ObservationIgnored private let updaterController: SPUStandardUpdaterController
    /// Sparkle holds its delegate weakly, so the controller keeps the relay alive.
    @ObservationIgnored private let relay: UpdateCycleRelay
    @ObservationIgnored private var scheduledChecksStarted = false
    /// Whether Sparkle can take a check now; tests replace it to simulate a rejected check.
    @ObservationIgnored var canStartCheck: () -> Bool

    /// Builds the updater without starting it, so tests never reach the network;
    /// the app calls `startScheduledChecks()` once at launch.
    init() {
        let relay = UpdateCycleRelay()
        relay.feedOverride = UpdatePreferences.feedOverride(fromEnvironment: ProcessInfo.processInfo.environment)
        let controller = SPUStandardUpdaterController(
            startingUpdater: false, updaterDelegate: relay, userDriverDelegate: nil)
        self.relay = relay
        updaterController = controller
        canStartCheck = { controller.updater.canCheckForUpdates }
        updateCardState = .idle(lastChecked: controller.updater.lastUpdateCheckDate)

        relay.onFoundUpdate = { [weak self] version in self?.handleFoundUpdate(version: version) }
        relay.onNoUpdate = { [weak self] in self?.handleNoUpdate() }
        relay.onCycleFinished = { [weak self] error in self?.handleCycleFinished(error: error) }
    }

    // MARK: - Scheduling

    /// Starts Sparkle's background checks, which follow `SUScheduledCheckInterval`
    /// (24h) in Info.plist. Idempotent.
    func startScheduledChecks() {
        guard !scheduledChecksStarted else { return }
        scheduledChecksStarted = true
        updaterController.startUpdater()
    }

    // MARK: - Checking

    /// The Settings button and the menu item. Sparkle shows its own prompt for
    /// a found release, with the install and relaunch option.
    func checkForUpdates() {
        // Sparkle ignores a check it cannot start (e.g. while a background download runs) and sends no cycle
        // callback for it, so `.checking` would never settle.
        guard canStartCheck() else { return }
        updateCardState = .checking
        updaterController.checkForUpdates(nil)
    }

    // MARK: - Sparkle callbacks

    func handleFoundUpdate(version: String) {
        pendingVersion = version
    }

    func handleNoUpdate() {
        pendingVersion = nil
    }

    /// Settles the card once a check (manual or scheduled) is over. Sparkle
    /// reports "no update" and a cancelled install as errors; neither is a failure.
    func handleCycleFinished(error: Error?) {
        if let error, !Self.isBenign(error) {
            Log.error("app", "update check failed: \(error.localizedDescription)")
            updateCardState = .failed(error.localizedDescription)
            return
        }
        if let pendingVersion {
            updateCardState = .available(version: pendingVersion)
        } else {
            updateCardState = .upToDate(lastChecked: updaterController.updater.lastUpdateCheckDate)
        }
    }

    /// Sparkle's error codes in `SUSparkleErrorDomain` (see SUErrors.h):
    /// `SUNoUpdateError` (1001) and `SUInstallationCanceledError` (4007).
    static func isBenign(_ error: Error) -> Bool {
        let nsError = error as NSError
        guard nsError.domain == SUSparkleErrorDomain else { return false }
        return nsError.code == 1001 || nsError.code == 4007
    }
}
