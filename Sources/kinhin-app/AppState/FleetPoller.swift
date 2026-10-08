import AppKit
import Foundation
import KinhinKit

/// The status poll's clock: how often to look, when to look early, and which
/// answers are still current. It knows nothing about the fleet; the
/// controller hands it the work to run each pass.
///
/// - Cadence: fast while a surface that shows live data (the main window or
///   the open menu) is up, slow while nothing is looking.
/// - Wake: opening a surface, or the Mac waking from sleep, cuts the wait short.
/// - Generation: `invalidate()` marks every answer already in flight as stale,
///   so a poll against a swapped-out backend can't publish.
@MainActor
final class FleetPoller {
    /// Poll cadence while a surface that shows live data is up, and while nothing is looking.
    var activeInterval: Duration = .seconds(3)
    var idleInterval: Duration = .seconds(12)
    private(set) var isMainWindowVisible = false
    private(set) var isMenuOpen = false
    private(set) var generation = 0

    private var task: Task<Void, Never>?
    private let wake = WakeSignal()
    private var wakeObserver: (any NSObjectProtocol)?

    /// Something on screen shows live fleet data (including CPU/RAM).
    var isUIActive: Bool { isMainWindowVisible || isMenuOpen }
    /// The interval the loop waits before its next look.
    var currentInterval: Duration { isUIActive ? activeInterval : idleInterval }
    var isRunning: Bool { task != nil }

    func setMainWindowVisible(_ visible: Bool) {
        let before = isUIActive
        isMainWindowVisible = visible
        if isUIActive != before { wake.signal() }
    }

    func setMenuOpen(_ open: Bool) {
        let before = isUIActive
        isMenuOpen = open
        if isUIActive != before { wake.signal() }
    }

    /// Marks answers requested before now as stale.
    func invalidate() { generation &+= 1 }

    /// Whether an answer requested at `generation` may still be published.
    func isCurrent(_ requested: Int) -> Bool { requested == generation }

    /// Runs `poll` now and then every `currentInterval` until `stop()`.
    /// `interval` pins both cadences (tests); nil keeps the adaptive ones.
    /// `onWake` runs after the Mac wakes from sleep, in addition to a `poll`.
    func start(
        every interval: Duration? = nil,
        poll: @escaping @MainActor () async -> Void,
        onWake: @escaping @MainActor () async -> Void = {}
    ) {
        guard task == nil else { return }
        if let interval {
            activeInterval = interval
            idleInterval = interval
        }
        // After a wake the picture on screen is stale and the daemon connection may have
        // dropped: look again straight away instead of waiting out the interval.
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { _ in
            Task { @MainActor in
                await poll()
                await onWake()
            }
        }
        task = Task { [weak self] in
            while !Task.isCancelled {
                await poll()
                guard let wait = self?.currentInterval, let wake = self?.wake else { return }
                // Sleep until the next look, or until a surface opens and
                // the cadence (and the usage sampling) should step up now.
                do {
                    try await wake.sleep(for: wait)
                } catch {
                    return
                }
            }
        }
    }

    func stop() {
        if let wakeObserver { NSWorkspace.shared.notificationCenter.removeObserver(wakeObserver) }
        wakeObserver = nil
        task?.cancel()
        task = nil
    }
}
