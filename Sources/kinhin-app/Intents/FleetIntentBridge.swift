import Foundation
import KinhinKit

/// What the App Intents need from the running app. The production default
/// forwards to `FleetController`; tests substitute a fake.
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
    /// Nil until the app delegate installs the live controller; intents then
    /// fail with "not set up" instead of reaching for a global.
    let controller: FleetController?

    init(controller: FleetController? = nil) {
        self.controller = controller
    }

    private var fleet: FleetController {
        get throws {
            guard let controller else { throw EngineError.fleetNotSetUp }
            return controller
        }
    }

    func status() async throws -> FleetStatus { try await fleet.fetchStatus() }

    /// Routed through the controller's pending-state bookkeeping, so a command
    /// begun from Shortcuts disables the menu items and flips the status item
    /// exactly like one begun in the app.
    func startFleet() async throws { try await fleet.perform(.start) }

    func stopFleet() async throws { try await fleet.perform(.stop) }

    func setPaused(_ paused: Bool) async throws { try await fleet.setPaused(paused) }

    func deleteVM(id: String) async throws { try await fleet.deleteVM(id: id) }

    func autoResumeEnabled() async throws -> Bool {
        guard let snapshot = try ConfigStore.snapshot(at: Paths.config) else {
            throw ConfigError.notFound(Paths.config.path)
        }
        return snapshot.autoResume
    }

    /// Routed through the controller so the same editor + engine push as the
    /// Capacity tab's Apply runs (including the not-set-up check).
    func setAutoResume(_ on: Bool) async throws { try await fleet.setAutoResumePolicy(on) }

    func doctor() async -> DoctorReport { await DoctorReportBuilder().build() }
}

/// Swappable so tests can drive the intents without an `AppDelegate`.
@MainActor
enum FleetIntentEnvironment {
    static var bridge: FleetIntentBridge = AppFleetIntentBridge()
}
