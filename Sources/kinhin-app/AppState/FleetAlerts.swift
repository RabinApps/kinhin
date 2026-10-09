import Foundation
import KinhinKit
@preconcurrency import UserNotifications

/// Something worth interrupting the user for.
struct FleetAlert: Equatable {
    let title: String
    let body: String
}

protocol FleetAlertPosting {
    func post(_ alert: FleetAlert)
}

/// Turns fleet poll results into notifications, once per change: a CI Mac nobody
/// is watching should still tell its owner that a token was rejected, the disk
/// is full or the daemon stopped answering, without anyone opening the app.
@MainActor
final class FleetAlerts {
    private let poster: any FleetAlertPosting
    private var lastError: String?
    private var wasReachable = false

    init(poster: any FleetAlertPosting = UserNotificationPoster()) {
        self.poster = poster
    }

    /// Call after every poll. `status` is nil when the fleet could not be read;
    /// `unreachableReason` says why (nil while setup is unfinished or polls work).
    func observe(status: FleetStatus?, unreachableReason: String?) {
        if let status {
            wasReachable = true
            let error = status.lastError
            if let error, error != lastError {
                poster.post(
                    FleetAlert(
                        title: String(
                            localized: "kinhin needs attention", bundle: .l10n,
                            comment: "Notification title when the fleet reports an error"), body: error))
            }
            lastError = error
        } else if let unreachableReason {
            // Only the reachable → unreachable edge: polls repeat every few seconds.
            if wasReachable {
                poster.post(
                    FleetAlert(
                        title: String(
                            localized: "kinhin fleet not responding", bundle: .l10n,
                            comment: "Notification title when the fleet stops answering"), body: unreachableReason))
            }
            wasReachable = false
        }
    }
}

/// Posts through UserNotifications. Does nothing outside a real `.app` bundle
/// (debug binaries, tests), where the framework would raise.
final class UserNotificationPoster: FleetAlertPosting {
    func post(_ alert: FleetAlert) {
        guard Bundle.main.bundleURL.pathExtension == "app" else { return }
        let center = UNUserNotificationCenter.current()
        center.requestAuthorization(options: [.alert, .sound]) { granted, error in
            if let error { Log.warn("app", "notification permission failed: \(error.localizedDescription)") }
            guard granted else { return }
            let content = UNMutableNotificationContent()
            content.title = alert.title
            content.body = alert.body
            let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
            center.add(request) { error in
                if let error { Log.warn("app", "could not post notification: \(error.localizedDescription)") }
            }
        }
    }
}

/// Keeps the Mac from idle-sleeping while the fleet is running: a sleeping Mac
/// drops its runners mid-job. The display may still sleep.
@MainActor
final class SleepPreventer {
    private var activity: NSObjectProtocol?
    private let begin: (String) -> NSObjectProtocol
    private let end: (NSObjectProtocol) -> Void

    init(
        begin: @escaping (String) -> NSObjectProtocol = {
            ProcessInfo.processInfo.beginActivity(
                options: [.idleSystemSleepDisabled, .suddenTerminationDisabled], reason: $0)
        },
        end: @escaping (NSObjectProtocol) -> Void = { ProcessInfo.processInfo.endActivity($0) }
    ) {
        self.begin = begin
        self.end = end
    }

    var isHolding: Bool { activity != nil }

    func update(fleetRunning: Bool, paused: Bool) {
        let shouldHold = fleetRunning && !paused
        if shouldHold, activity == nil {
            activity = begin(
                String(
                    localized: "kinhin is serving CI jobs", bundle: .l10n,
                    comment: "Reason shown by macOS for keeping the Mac awake while CI jobs run"))
        } else if !shouldHold, let held = activity {
            end(held)
            activity = nil
        }
    }
}
