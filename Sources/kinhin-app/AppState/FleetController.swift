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

    /// Who runs the fleet: nil until setup is complete.
    @ObservationIgnored var service: (any FleetServing)?
    /// Config-edit push (debounced): a burst of edits flushes once.
    @ObservationIgnored var pendingConfigEdits = false
    @ObservationIgnored var isConfigPushScheduled = false
    @ObservationIgnored var configPushDelay: Duration = .seconds(1)
    /// Test seam: replaces the engine/daemon reload the debounce flushes into.
    @ObservationIgnored var configFlushOverride: (() async -> Void)?
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

    func refresh() async {
        // Polled every few seconds (daemon calls run off the main thread): an
        // unreachable or wedged daemon simply reads as "not running" in the
        // status item, so a failure here is expected (status stays nil).
        status = try? await service?.status()
    }

    // MARK: - Actions

    /// Runs a start/stop with the pending-state bookkeeping shared by every
    /// entry point (menu item, Fleet tab button, App Intent). Throws when no
    /// backend is available — the menu wrappers alert, and an App Intent
    /// must fail in Shortcuts rather than report success.
    func perform(_ action: FleetAction) async throws {
        defer { pendingFleetAction = nil }
        pendingFleetAction = action
        guard let service else { throw EngineError.fleetNotSetUp }
        if action == .start { try await service.start() } else { try await service.stop() }
        await refresh()
    }

    /// Pauses or resumes the fleet through whichever backend is live.
    func setPaused(_ paused: Bool) async throws {
        guard let service else { throw EngineError.fleetNotSetUp }
        try await service.setPaused(paused)
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
        try await service.deleteVM(id: id)
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
