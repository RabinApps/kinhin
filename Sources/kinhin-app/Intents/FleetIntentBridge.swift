import AppKit
import KinhinKit

/// What the App Intents need from the running app. The production default
/// forwards to `AppDelegate`; tests substitute a fake.
@MainActor
protocol FleetIntentBridge {
    func status() async throws -> FleetStatus
    func setPaused(_ paused: Bool) async throws
    func doctor() async -> DoctorReport
}

@MainActor
struct AppFleetIntentBridge: FleetIntentBridge {
    private var delegate: AppDelegate {
        get throws {
            guard let delegate = NSApp.delegate as? AppDelegate else { throw FleetAccessError.notSetUp }
            return delegate
        }
    }

    func status() async throws -> FleetStatus { try await delegate.fleetStatus() }

    func setPaused(_ paused: Bool) async throws { try await delegate.setFleetPaused(paused) }

    func doctor() async -> DoctorReport { await DoctorReportBuilder().build() }
}

/// Swappable so tests can drive the intents without an `AppDelegate`.
@MainActor
enum FleetIntentEnvironment {
    static var bridge: FleetIntentBridge = AppFleetIntentBridge()
}
