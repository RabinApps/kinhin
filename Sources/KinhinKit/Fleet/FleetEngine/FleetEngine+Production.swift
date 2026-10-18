import Foundation

// FleetEngine — the production wiring every host process (daemon, app,
// `kinhin start`) builds its engine with.
extension FleetEngine {
    /// An engine for `config` on this Mac: tart at the configured path, the
    /// shared fleet store, SSH, a live host snapshot and live disk probing.
    /// `token` is the engine token from `ConfigLoader.engineToken(for:)`.
    /// Throws when tart can't be resolved.
    public static func production(config: KinhinConfig, token: String) throws -> FleetEngine {
        FleetEngine(
            config: config,
            pat: token,
            tart: try config.makeTartControlling(),
            store: FleetStore(),
            ssh: SSHExecutor(),
            host: ResourceProbe().snapshot(),
            dependencies: .live(healing: config.healing)
        )
    }
}
