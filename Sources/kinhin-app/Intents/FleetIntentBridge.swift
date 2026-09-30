import AppKit
import KinhinKit

/// What the App Intents need from the running app. The production default
/// forwards to `AppDelegate`; tests substitute a fake.
@MainActor
protocol FleetIntentBridge: Sendable {
    func status() async throws -> FleetStatus
    func startFleet() async throws
    func stopFleet() async throws
    func setPaused(_ paused: Bool) async throws
    func deleteVM(id: String) async throws
    func autoResumeEnabled() async throws -> Bool
    func setAutoResume(_ on: Bool) async throws
    func doctor() async -> DoctorReport
}

@MainActor
struct AppFleetIntentBridge: FleetIntentBridge {
    private var delegate: AppDelegate {
        get throws {
            guard let delegate = NSApp.delegate as? AppDelegate else { throw EngineError.fleetNotSetUp }
            return delegate
        }
    }

    func status() async throws -> FleetStatus { try await delegate.fleetStatus() }

    /// Routed through the delegate's pending-state bookkeeping, so a command
    /// begun from Shortcuts disables the menu items and flips the status item
    /// exactly like one begun in the app.
    func startFleet() async throws { try await delegate.performFleetAction(.start) }

    func stopFleet() async throws { try await delegate.performFleetAction(.stop) }

    func setPaused(_ paused: Bool) async throws { try await delegate.setFleetPaused(paused) }

    func deleteVM(id: String) async throws { try await delegate.performVMDelete(id: id) }

    func autoResumeEnabled() async throws -> Bool {
        guard let snapshot = try ConfigStore.snapshot(at: Paths.config) else {
            throw ConfigError.notFound(Paths.config.path)
        }
        return snapshot.autoResume
    }

    /// Routed through the delegate so the same editor + engine push as the
    /// Capacity tab's Apply runs (including the not-set-up check).
    func setAutoResume(_ on: Bool) async throws { try await delegate.setAutoResumePolicy(on) }

    func doctor() async -> DoctorReport { await DoctorReportBuilder().build() }
}

/// Swappable so tests can drive the intents without an `AppDelegate`.
@MainActor
enum FleetIntentEnvironment {
    static var bridge: FleetIntentBridge = AppFleetIntentBridge()
}
