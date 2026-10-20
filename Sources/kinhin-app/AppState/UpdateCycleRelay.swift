import Sparkle

/// Forwards Sparkle's updater callbacks to `UpdateController`. Sparkle declares
/// `SPUUpdaterDelegate` main-actor isolated, so the relay runs on the main actor.
@MainActor
final class UpdateCycleRelay: NSObject, SPUUpdaterDelegate {
    var onFoundUpdate: ((String) -> Void)?
    var onNoUpdate: (() -> Void)?
    var onCycleFinished: ((Error?) -> Void)?
    /// Replaces the appcast URL from Info.plist (KINHIN_UPDATE_FEED; see `UpdatePreferences`).
    var feedOverride: String?

    func feedURLString(for updater: SPUUpdater) -> String? {
        feedOverride
    }

    func updater(_ updater: SPUUpdater, didFindValidUpdate item: SUAppcastItem) {
        onFoundUpdate?(item.displayVersionString)
    }

    func updaterDidNotFindUpdate(_ updater: SPUUpdater) {
        onNoUpdate?()
    }

    func updater(_ updater: SPUUpdater, didFinishUpdateCycleFor updateCheck: SPUUpdateCheck, error: Error?) {
        onCycleFinished?(error)
    }
}
