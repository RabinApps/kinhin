import AppKit
import Foundation
import KinhinKit
import Observation

/// The app's single source of truth for the fleet: the latest polled status,
/// the in-flight start/stop, and the live backend. The status item, menu, Fleet
/// tab and App Intents all read this one object (and act through it), so there
/// are no mirrored copies to keep in sync.
@MainActor
@Observable
final class FleetController {
    /// Latest status from the poll; nil until the first poll, when setup is
    /// unfinished, or when the daemon is unreachable.
    var status: FleetStatus?

    /// A fleet start/stop command in flight (menu item, Fleet tab, or App
    /// Intent). The status item shows "Starting…"/"Stopping…" and the fleet
    /// controls disable until the command and its status refresh complete.
    var pendingFleetAction: FleetAction?

    /// Set while first-run onboarding is up (or no usable config exists).
    var setupIncomplete = false

    /// Why the last poll failed (daemon down, RPC timeout); nil while polls
    /// succeed. Distinguishes "can't reach the fleet" from "setup unfinished".
    private(set) var unreachableReason: String?

    /// Who runs the fleet: nil until setup is complete. Replacing it bumps
    /// `serviceGeneration`, so a poll that was in flight against the old one
    /// can't publish its answer.
    @ObservationIgnored var service: (any FleetServing)? {
        didSet { serviceGeneration &+= 1 }
    }
    @ObservationIgnored private var serviceGeneration = 0
    /// The production backend: the in-process engine or the daemon. Reads
    /// and writes go through `service` (so a swap bumps `serviceGeneration`
    /// and an in-flight poll can't publish a stale answer); tests set it
    /// directly.
    @ObservationIgnored var backend: FleetBackend? {
        get { service as? FleetBackend }
        set { service = newValue }
    }
    /// A start/stop is executing (distinct from the UI-visible pending flag,
    /// which the Fleet button sets a tick earlier).
    @ObservationIgnored private var commandInFlight = false
    /// Config-edit push (debounced): a burst of edits flushes once.
    @ObservationIgnored var pendingConfigEdits = false
    @ObservationIgnored var isConfigPushScheduled = false
    @ObservationIgnored var configPushDelay: Duration = .seconds(1)
    /// Test seam: replaces the engine/daemon reload the debounce flushes into.
    @ObservationIgnored var configFlushOverride: (() async -> Void)?
    /// The config file edits are read from (tests point this at a scratch file).
    @ObservationIgnored var configURL: URL = Paths.config
    /// How a rebuilt in-process engine gets its forge token and is built;
    /// production defaults hit the Keychain and the real runtimes.
    /// The blocking seams (Keychain, a daemon ping, host probes) are
    /// `@Sendable` so the controller runs them off the main actor.
    @ObservationIgnored var engineToken: @Sendable (KinhinConfig) throws -> String? = {
        try ConfigLoader.engineToken(for: $0)
    }
    @ObservationIgnored var makeEngine: (KinhinConfig, String) throws -> FleetEngine = {
        try FleetEngine.production(config: $0, token: $1)
    }
    @ObservationIgnored var hostSnapshot: @Sendable () -> HostResources = { ResourceProbe().snapshot() }
    /// Whether a daemon is serving this Mac, and how to talk to it. Checked
    /// only while the app has no backend of its own.
    @ObservationIgnored var daemonProbe: @Sendable () -> Bool = { RPCClient.isDaemonAlive() }
    @ObservationIgnored var makeDaemonBackend: () -> any FleetServing = { FleetBackend.daemon(RPCClient()) }
    /// A LaunchAgent plist exists but points at a binary that no longer exists
    /// on disk (e.g. the app was removed without `kinhin daemon uninstall`).
    /// Nil when the plist is absent, points at a live binary, or cannot be read.
    var staleDaemonPlist: String?
    /// The disk-pressure banner was dismissed this session: keep it hidden while
    /// the same pressure episode persists. Re-armed once the engine reports
    /// pressure has eased, so the next episode shows the banner again.
    @ObservationIgnored private var diskPressureDismissed = false

    @ObservationIgnored private var pollTask: Task<Void, Never>?
    /// Wakes the poll loop's sleep (a surface opened, so look now).
    @ObservationIgnored private let pollWake = WakeSignal()

    // MARK: - Visibility (adaptive polling)

    /// Poll cadence while a surface that shows live data (the main window or
    /// the open menu) is up, and while nothing is looking.
    @ObservationIgnored var activeInterval: Duration = .seconds(3)
    @ObservationIgnored var idleInterval: Duration = .seconds(12)
    @ObservationIgnored private(set) var isMainWindowVisible = false
    @ObservationIgnored private(set) var isMenuOpen = false
    /// Something on screen shows live fleet data (including CPU/RAM).
    var isUIActive: Bool { isMainWindowVisible || isMenuOpen }
    /// The interval the poll loop waits before its next look.
    var currentPollInterval: Duration { isUIActive ? activeInterval : idleInterval }

    func setMainWindowVisible(_ visible: Bool) {
        let before = isUIActive
        isMainWindowVisible = visible
        if isUIActive != before { pollWake.signal() }
    }

    func setMenuOpen(_ open: Bool) {
        let before = isUIActive
        isMenuOpen = open
        if isUIActive != before { pollWake.signal() }
    }
    /// Notifications for state changes nobody is watching for, and the sleep guard
    /// held while the fleet serves jobs. Both are driven from `refresh()`.
    @ObservationIgnored var alerts = FleetAlerts()
    @ObservationIgnored var sleepPreventer = SleepPreventer()
    @ObservationIgnored private var wakeObserver: (any NSObjectProtocol)?

    /// The production backend, when `service` is one.
    /// The in-process engine, when this app runs the fleet itself.
    var engine: FleetEngine? { (service as? FleetBackend)?.engine }

    /// The attached forges across all accounts, in the order the engine
    /// attached them (or the daemon reports them). Nil before the first
    /// status poll, when there is no queue to act on.
    var attachedForges: [String: Forge] {
        guard let _ = service as? FleetBackend else { return [:] }
        if let engine { return engine.forges }
        return [:]  // a daemon currently has no forge-API surface
    }

    // MARK: - Polling

    /// Polls the backend until `stopPolling()`. Started by the app delegate
    /// at launch, so tests that build a controller never poll.
    /// `interval` pins both cadences (tests); nil keeps the adaptive ones.
    func startPolling(every interval: Duration? = nil) {
        guard pollTask == nil else { return }
        if let interval {
            activeInterval = interval
            idleInterval = interval
        }
        // After a wake the picture on screen is stale and the daemon connection may have
        // dropped: look again straight away instead of waiting out the interval.
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                await self?.refresh()
                await self?.detectStaleDaemonPlist()
            }
        }
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refresh()
                guard let wait = self?.currentPollInterval, let wake = self?.pollWake else { return }
                // Sleep until the next look — or until a surface opens and
                // the cadence (and the usage sampling) should step up now.
                do {
                    try await wake.sleep(for: wait)
                } catch {
                    return
                }
            }
        }
    }

    func stopPolling() {
        if let wakeObserver { NSWorkspace.shared.notificationCenter.removeObserver(wakeObserver) }
        wakeObserver = nil
        pollTask?.cancel()
        pollTask = nil
    }

    /// Checks whether a LaunchAgent plist exists but points at a binary that
    /// no longer exists on disk, and stores a human-readable notice.
    func detectStaleDaemonPlist() {
        staleDaemonPlist =
            Daemon.isPlistStale
            ? "the daemon LaunchAgent is installed but its binary is missing — run `kinhin daemon uninstall` to remove it"
            : nil
    }

    /// Quit-time teardown: stop polling and stop the in-process engine (which
    /// tears its VMs down), waiting up to `timeout`. A running daemon owns its
    /// own fleet and is left alone.
    func shutdown(timeout: Duration = .seconds(30)) async {
        stopPolling()
        guard let engine else { return }
        let finished = await runWithTimeout(timeout) { await engine.stop() }
        if !finished {
            Log.warn("app", "engine did not stop within \(timeout) — quitting anyway; the next launch adopts survivors")
        }
    }

    func refresh() async {
        guard let polled = service else {
            // No backend of our own: adopt a daemon that has started since
            // launch (with an engine of our own we never do — two fleets
            // would fight over the same VMs).
            // Off the main actor: the probe pings a socket with a deadline.
            let probe = daemonProbe
            let daemonAlive = await Task.detached { probe() }.value
            guard service == nil else { return }  // a backend appeared while the probe ran
            if daemonAlive {
                Log.info("app", "a daemon is now serving this Mac — attaching to it")
                service = makeDaemonBackend()
                setupIncomplete = false
                await refresh()
                return
            }
            publish(status: nil, unreachableReason: nil, sideEffects: false)
            return
        }
        let generation = serviceGeneration
        do {
            let fresh = try await polled.status(includeUsage: isUIActive)
            guard generation == serviceGeneration else { return }  // the backend was swapped mid-poll
            publish(status: fresh, unreachableReason: nil)
        } catch is CancellationError {
            return
        } catch {
            // Polled every few seconds (daemon calls run off the main thread):
            // an unreachable or wedged daemon is expected, so it is kept as a
            // reason the UI shows ("not responding"), not an error dialog.
            guard generation == serviceGeneration else { return }
            // Log the transition only: the poll repeats every few seconds.
            if unreachableReason == nil { Log.warn("app", "fleet poll failed: \(error.localizedDescription)") }
            publish(status: nil, unreachableReason: error.localizedDescription)
        }
    }

    /// Assigns the poll's answer only where it changed: an @Observable setter
    /// notifies on every write, which would re-render the menu and the
    /// SwiftUI views on each poll even when nothing differs.
    private func publish(status newStatus: FleetStatus?, unreachableReason newReason: String?, sideEffects: Bool = true)
    {
        let polled = suppressingDismissedDiskPressure(newStatus)
        if status != polled { status = polled }
        if unreachableReason != newReason { unreachableReason = newReason }
        if sideEffects { publishSideEffects() }
    }

    /// Applies the session's disk-pressure dismissal to a polled status: the
    /// banner stays hidden while the dismissed episode persists (the engine
    /// keeps reporting it every pass), and the latch re-arms — showing the
    /// banner again — once the engine reports pressure has eased.
    private func suppressingDismissedDiskPressure(_ newStatus: FleetStatus?) -> FleetStatus? {
        guard var polled = newStatus else { return newStatus }
        if polled.diskPressureNotice == nil {
            diskPressureDismissed = false
        } else if diskPressureDismissed {
            polled.diskPressureNotice = nil
        }
        return polled
    }

    private func publishSideEffects() {
        alerts.observe(status: status, unreachableReason: unreachableReason)
        sleepPreventer.update(fleetRunning: status?.running ?? false, paused: status?.paused ?? false)
    }

    /// A short label for who is running the fleet: the in-process engine or
    /// the background daemon. Nil while no backend is attached (setup
    /// unfinished, or before the first poll).
    var fleetMode: String? {
        switch service {
        case is FleetBackend: break
        default: return nil
        }
        guard let backend = service as? FleetBackend else { return nil }
        switch backend {
        case .inProcess: return "in-process engine"
        case .daemon: return "background daemon"
        }
    }

    /// The status line shared by the menu and the Fleet tab.
    var statusLine: String {
        let base: String
        if let status {
            base = FleetStatusFormatter.summary(status)
        } else if service == nil {
            base = FleetStatusFormatter.summary(nil)
        }  // setup unfinished
        else if let unreachableReason {
            base = "Fleet not responding — \(unreachableReason)"
        } else {
            base = "Checking the fleet…"
        }
        var line = base
        if let mode = fleetMode {
            line += "\n  \(mode)"
        }
        if let stale = staleDaemonPlist {
            line += "\n  ⚠ \(stale)"
        }
        return line
    }

    // MARK: - Actions

    /// Runs a start/stop with the pending-state bookkeeping shared by every
    /// entry point (menu item, Fleet tab button, App Intent). Throws when no
    /// backend is available — the menu wrappers alert, and an App Intent
    /// must fail in Shortcuts rather than report success.
    func perform(_ action: FleetAction) async throws {
        guard !commandInFlight else { throw EngineError.fleetBusy }
        commandInFlight = true
        defer {
            commandInFlight = false
            pendingFleetAction = nil
        }
        pendingFleetAction = action
        guard let service else { throw EngineError.fleetNotSetUp }
        do {
            switch action {
            case .start:
                try await service.start()
            case .stop:
                try await service.stop()
            case .requeueQueuedJobs(let forge):
                try await service.requeueQueuedJobs(for: forge)
            case .skipQueuedJobs(let forge):
                try await service.skipQueuedJobs(for: forge)
            }
        } catch {
            // A failed command may still have changed things; don't leave the
            // last poll's picture on screen.
            await refresh()
            throw error
        }
        await refresh()
    }

    /// Pauses or resumes the fleet through whichever backend is live.
    func setPaused(_ paused: Bool) async throws {
        guard let service else { throw EngineError.fleetNotSetUp }
        do {
            try await service.setPaused(paused)
        } catch {
            await refresh()
            throw error
        }
        await refresh()
    }

    /// Current fleet status straight from the backend (not the cached poll).
    func fetchStatus() async throws -> FleetStatus {
        guard let service else { throw EngineError.fleetNotSetUp }
        return try await service.status()
    }

    /// The live pipeline a VM is running, straight from the backend (the
    /// pipeline sheet polls this while it is open).
    func fetchPipelineDetail(vmID: String) async throws -> PipelineDetail? {
        guard let service else { throw EngineError.fleetNotSetUp }
        return try await service.pipelineDetail(vmID: vmID)
    }

    /// The output of a step (or job) of a VM's pipeline, straight from the backend.
    func fetchPipelineLog(vmID: String, jobID: String, stepIndex: Int?) async throws -> PipelineLog? {
        guard let service else { throw EngineError.fleetNotSetUp }
        return try await service.pipelineLog(vmID: vmID, jobID: jobID, stepIndex: stepIndex)
    }

    /// Deletes a VM without asking first; entry points confirm in their own
    /// UX (menu shows an alert; the App Intent relies on Shortcuts' confirm).
    func deleteVM(id: String) async throws {
        guard let service else { throw EngineError.fleetNotSetUp }
        do {
            try await service.deleteVM(id: id)
        } catch {
            await refresh()
            throw error
        }
        await refresh()
    }

    /// Requeue the queued jobs of one forge. The status refresh replays the
    /// new queue so the UI shows the work coming back.
    func requeueQueuedJobs(for forge: ForgeID) async throws {
        guard let service else { throw EngineError.fleetNotSetUp }
        try await service.requeueQueuedJobs(for: forge)
        await refresh()
    }

    func skipQueuedJobs(for forge: ForgeID) async throws {
        guard let service else { throw EngineError.fleetNotSetUp }
        try await service.skipQueuedJobs(for: forge)
        await refresh()
    }

    /// Hands a saved token to whoever owns the engine so it takes effect
    /// without a restart.
    func rotate(_ target: CredentialRotation.Target, token: String) async throws {
        if let service {
            try await service.rotate(target, token: token)
            Log.info("app", "replaced token for '\(target.accountName)' (\(service.logName))")
        } else {
            Log.info("app", "stored token for '\(target.accountName)' (no engine running yet)")
        }
        await refresh()
    }

    /// Clears the session-scoped disk-pressure banner from the Fleet tab. The
    /// dismissal holds while the same pressure episode persists — the engine
    /// keeps reporting it every poll and the app keeps suppressing it — so a
    /// dismiss is "not now" rather than "fixed it for good": the next episode
    /// (or the next launch) shows the banner again.
    func clearDiskPressureNotice() {
        diskPressureDismissed = true
        status?.diskPressureNotice = nil
    }
}
