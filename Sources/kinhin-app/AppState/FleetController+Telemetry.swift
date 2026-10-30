import Foundation
import KinhinKit

/// Where the Telemetry card's numbers come from.
enum TelemetryReading: Equatable {
    /// This app runs the engine, so its own `TelemetryService` owns the exporters.
    case inProcess(TelemetryStatus)
    /// A daemon runs the fleet and exports for it; the app asked it over RPC.
    case daemon(TelemetryStatus)
    /// A daemon runs the fleet but would not say (it stopped mid-poll, or predates the `telemetry_status` call).
    case daemonUnreachable(String)
    /// No fleet runs here, so nothing exports.
    case noFleet
}

@MainActor
extension FleetController {
    /// The telemetry pipeline's status from whoever owns the exporters. Never creates one: an app attached to a
    /// daemon only reads the daemon's, and with no fleet nothing is running.
    func readTelemetry() async -> TelemetryReading {
        if engine != nil { return .inProcess(await environment.ownTelemetryStatus()) }
        guard case .daemon? = backend else { return .noFleet }
        let ask = environment.daemonTelemetryStatus
        // The RPC is a blocking socket call.
        let answer = await Task.detached { Result { try ask() } }.value
        switch answer {
        case .success(let status): return .daemon(status)
        case .failure(let error): return .daemonUnreachable(error.localizedDescription)
        }
    }
}
