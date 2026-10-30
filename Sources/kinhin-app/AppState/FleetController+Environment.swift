import Foundation
import KinhinKit

extension FleetController {
    /// Everything `FleetController` reaches outside the process for: the
    /// Keychain, the host probes, a daemon ping, engine construction and the
    /// config file. Production defaults hit the real thing; tests replace the
    /// fields they care about. The blocking seams (Keychain, a daemon ping,
    /// host probes) are `@Sendable` so the controller runs them off the main
    /// actor.
    struct Environment {
        /// The engine token for a config (the Keychain, or env in debug builds).
        var engineToken: @Sendable (KinhinConfig) throws -> String? = {
            try ConfigLoader.engineToken(for: $0)
        }
        /// How a rebuilt in-process engine is built.
        var makeEngine: (KinhinConfig, String) throws -> FleetEngine = {
            try FleetEngine.production(config: $0, token: $1)
        }
        var hostSnapshot: @Sendable () -> HostResources = { ResourceProbe().snapshot() }
        /// Whether a daemon is serving this Mac. Checked only while the app has no backend of its own.
        var daemonProbe: @Sendable () -> Bool = { RPCClient.isDaemonAlive() }
        /// How to talk to a daemon that has started since launch.
        var makeDaemonBackend: () -> any FleetServing = { FleetBackend.daemon(RPCClient()) }
        /// The config file edits are read from (tests point this at a scratch file).
        var configURL: URL = Paths.config
        /// Starts, restarts or stops the process's exporters to match the config. Called only while this app runs
        /// the engine itself: an app attached to a daemon never owns exporters (the daemon exports for that fleet).
        var applyTelemetry: @Sendable (KinhinConfig.TelemetryConfig) async -> Void = {
            _ = await TelemetryService.shared.apply($0)
        }
        /// Flushes and stops the exporters on quit (bounded inside `TelemetryService`, and again by the caller).
        var shutdownTelemetry: @Sendable () async -> Void = { await TelemetryService.shared.shutdown() }
        /// What this process's own exporters are doing (the app runs the engine in-process).
        var ownTelemetryStatus: @Sendable () async -> TelemetryStatus = { await TelemetryService.shared.status() }
        /// What the daemon's exporters are doing (a blocking socket call: run off the main actor).
        var daemonTelemetryStatus: @Sendable () throws -> TelemetryStatus = { try RPCClient().telemetryStatus() }
    }
}
