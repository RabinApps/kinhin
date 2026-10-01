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
    @ObservationIgnored var engineToken: (KinhinConfig) throws -> String? = { try ConfigLoader.engineToken(for: $0) }
    @ObservationIgnored var makeEngine: (KinhinConfig, String) throws -> FleetEngine = {
        try FleetEngine.production(config: $0, token: $1)
    }
    @ObservationIgnored var hostSnapshot: () -> HostResources = { ResourceProbe().snapshot() }
    @ObservationIgnored private var pollTask: Task<Void, Never>?

    /// The production backend, when `service` is one.
    var backend: FleetBackend? {
        get { service as? FleetBackend }
        set { service = newValue }
    }

    /// The in-process engine, when this app runs the fleet itself.
    var engine: FleetEngine? { backend?.engine }

    // MARK: - Polling

    /// Polls the backend until `stopPolling()`. Started by the app delegate
    /// at launch, so tests that build a controller never poll.
    func startPolling(every interval: Duration = .seconds(3)) {
        guard pollTask == nil else { return }
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refresh()
                do {
                    try await Task.sleep(for: interval)
                } catch {
                    return
                }
            }
        }
    }

    func stopPolling() {
        pollTask?.cancel()
        pollTask = nil
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
            status = nil
            unreachableReason = nil
            return
        }
        let generation = serviceGeneration
        do {
            let fresh = try await polled.status()
            guard generation == serviceGeneration else { return }  // the backend was swapped mid-poll
            status = fresh
            unreachableReason = nil
        } catch is CancellationError {
            return
        } catch {
            // Polled every few seconds (daemon calls run off the main thread):
            // an unreachable or wedged daemon is expected, so it is kept as a
            // reason the UI shows ("not responding"), not an error dialog.
            guard generation == serviceGeneration else { return }
            // Log the transition only: the poll repeats every few seconds.
            if unreachableReason == nil { Log.warn("app", "fleet poll failed: \(error.localizedDescription)") }
            status = nil
            unreachableReason = error.localizedDescription
        }
    }

    /// The status line shared by the menu and the Fleet tab.
    var statusLine: String {
        if let status { return FleetStatusFormatter.summary(status) }
        if service == nil { return FleetStatusFormatter.summary(nil) }  // setup unfinished
        if let unreachableReason { return "Fleet not responding — \(unreachableReason)" }
        return "Checking the fleet…"
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
            if action == .start { try await service.start() } else { try await service.stop() }
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
}
