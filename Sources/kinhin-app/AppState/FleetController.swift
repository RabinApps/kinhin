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
        didSet { poller.invalidate() }
    }
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
    @ObservationIgnored let configPush = ConfigPushScheduler()
    /// A pending config push came from a save in the window: a failure to
    /// apply it also alerts. Read and reset by each flush.
    @ObservationIgnored var configPushAlertsOnFailure = false
    /// Everything the controller reaches outside the process for (Keychain,
    /// host probes, daemon ping, engine construction, the config file).
    @ObservationIgnored var environment = Environment()
    /// A LaunchAgent plist exists but points at a binary that no longer exists
    /// on disk (e.g. the app was removed without `kinhin daemon uninstall`).
    /// Nil when the plist is absent, points at a live binary, or cannot be read.
    var staleDaemonPlist: String?
    /// Failures the app hit on its own, keyed by where they came from: the
    /// launch-time engine build or auto-start, a config edit that couldn't be
    /// applied. They happen in the app, not the engine, so the polled status
    /// can't carry them; the menu and the Fleet tab show them under the status
    /// line until the same step next succeeds.
    private(set) var problems: [FleetProblem: String] = [:]
    /// The disk-pressure banner was dismissed this session: keep it hidden while
    /// the same pressure episode persists. Re-armed once the engine reports
    /// pressure has eased, so the next episode shows the banner again.
    @ObservationIgnored private var diskPressureDismissed = false

    /// The poll's cadence, wake-ups and stale-answer guard.
    @ObservationIgnored let poller = FleetPoller()

    // MARK: - Visibility (adaptive polling)

    /// Something on screen shows live fleet data (including CPU/RAM).
    var isUIActive: Bool { poller.isUIActive }
    /// The interval the poll loop waits before its next look.
    var currentPollInterval: Duration { poller.currentInterval }

    func setMainWindowVisible(_ visible: Bool) { poller.setMainWindowVisible(visible) }

    func setMenuOpen(_ open: Bool) { poller.setMenuOpen(open) }

    /// Notifications for state changes nobody is watching for, and the sleep guard
    /// held while the fleet serves jobs. Both are driven from `refresh()`.
    @ObservationIgnored var alerts = FleetAlerts()
    @ObservationIgnored var sleepPreventer = SleepPreventer()

    init() {
        configPush.flush = { [weak self] in await self?.applyConfigToEngine() }
    }

    /// The in-process engine, when this app runs the fleet itself.
    var engine: FleetEngine? { (service as? FleetBackend)?.engine }

    /// The attached forges across all accounts, in the order the engine
    /// attached them (or the daemon reports them). Nil before the first
    /// status poll, when there is no queue to act on.
    var attachedForges: [String: Forge] {
        guard let _ = service as? FleetBackend else { return [:] }
        if let engine { return engine.forges }
        // A daemon has no forge-API surface: `Forge` clients are live objects and `FleetStatus`
        // carries no forge list, so the per-forge requeue/skip rows are empty in daemon mode
        // (the Fleet tab shows its "no forges attached" hint). Exposing it needs a new RPC.
        return [:]
    }

    // MARK: - Polling

    /// Polls the backend until `stopPolling()`. Started by the app delegate
    /// at launch, so tests that build a controller never poll.
    /// `interval` pins both cadences (tests); nil keeps the adaptive ones.
    func startPolling(every interval: Duration? = nil) {
        poller.start(
            every: interval,
            poll: { [weak self] in await self?.refresh() },
            onWake: { [weak self] in self?.detectStaleDaemonPlist() })
    }

    func stopPolling() { poller.stop() }

    /// Checks whether a LaunchAgent plist exists but points at a binary that
    /// no longer exists on disk, and stores a human-readable notice.
    func detectStaleDaemonPlist() {
        staleDaemonPlist =
            Daemon.isPlistStale
            ? String(
                localized:
                    "the daemon LaunchAgent is installed but its binary is missing — run `kinhin daemon uninstall` to remove it",
                bundle: .l10n,
                comment: "Warning shown under the fleet status; the backticked command must stay verbatim")
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
            let probe = environment.daemonProbe
            let daemonAlive = await Task.detached { probe() }.value
            guard service == nil else { return }  // a backend appeared while the probe ran
            if daemonAlive {
                Log.info("app", "a daemon is now serving this Mac — attaching to it")
                service = environment.makeDaemonBackend()
                setupIncomplete = false
                await refresh()
                return
            }
            publish(status: nil, unreachableReason: nil, sideEffects: false)
            return
        }
        let generation = poller.generation
        do {
            let fresh = try await polled.status(includeUsage: isUIActive)
            guard poller.isCurrent(generation) else { return }  // the backend was swapped mid-poll
            publish(status: fresh, unreachableReason: nil)
        } catch is CancellationError {
            return
        } catch {
            // Polled every few seconds (daemon calls run off the main thread):
            // an unreachable or wedged daemon is expected, so it is kept as a
            // reason the UI shows ("not responding"), not an error dialog.
            guard poller.isCurrent(generation) else { return }
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
        case .inProcess:
            return String(
                localized: "in-process engine", bundle: .l10n,
                comment: "Short label: the fleet runs inside the app process")
        case .daemon:
            return String(
                localized: "background daemon", bundle: .l10n,
                comment: "Short label: the fleet runs in the background daemon")
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
            base = String(
                localized: "Fleet not responding — \(unreachableReason)", bundle: .l10n,
                comment: "Status line when the fleet can't be reached; %@ is the reason")
        } else {
            base = String(
                localized: "Checking the fleet…", bundle: .l10n, comment: "Status line while the first poll is pending")
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
        // A start that worked answers a failed one at launch.
        if action == .start { setProblem(.launch, nil) }
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

    // MARK: - App-side problems

    /// The current problems, in a stable order (launch first).
    var problemLines: [String] { problems.sorted { $0.key.rawValue < $1.key.rawValue }.map(\.value) }

    /// Records (or, with nil, clears) the problem from `source`. Writes only on
    /// a change, so an unchanged report doesn't re-render the menu.
    func setProblem(_ source: FleetProblem, _ message: String?) {
        if problems[source] != message { problems[source] = message }
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

/// Where an app-side fleet problem came from (`FleetController.problems`).
enum FleetProblem: Int, Sendable {
    /// Launch: config.yaml unreadable, the engine couldn't be built, or auto-start failed.
    case launch
    /// A saved config edit couldn't be applied to the running fleet.
    case configPush
}
