import Foundation

/// The storage locations this process uses, taken from the Mac's own config (`ConfigLoader.load()` applies them).
/// One process-wide value, because the trees it names are process-wide too: every `tart` the process starts reads
/// `TART_HOME` from the environment, and `Paths.toolchainCache`, the Docker Hub cache and `container system start`
/// are reached from the engine, healing, setup, image builds and the CLI alike. Until a config is applied, and for
/// every key the config leaves out, the default locations apply.
public enum StorageLocations {
    private struct State: Sendable {
        var storage = KinhinConfig.StorageConfig()
        /// Whether the Mac's config has been applied yet (until then, `storage` is only the default).
        var applied = false
        /// `TART_HOME` as the process inherited it, recorded the first time kinhin overrides it, so a config that
        /// drops `tart_home:` hands the inherited value back instead of keeping a stale one.
        var inheritedTartHome: String??
    }

    private static let state = Locked(State())

    /// The storage settings in effect.
    public static var current: KinhinConfig.StorageConfig { state.withLock { $0.storage } }

    /// Whether `apply` has run in this process. Before that, a default path is not known to be the one in use.
    public static var isApplied: Bool { state.withLock { $0.applied } }

    /// Makes `storage` the process's storage settings and exports `TART_HOME` to match, so every `tart` child
    /// (clone, run, list, usage sampling) uses the configured home. Called on every load of the Mac's config, which
    /// is also how a config reload takes effect.
    public static func apply(_ storage: KinhinConfig.StorageConfig) {
        state.withLock { state in
            state.storage = storage
            state.applied = true
            if let home = storage.tartHome {
                if state.inheritedTartHome == nil {
                    state.inheritedTartHome = .some(ProcessInfo.processInfo.environment[tartHomeVariable])
                }
                setenv(tartHomeVariable, home, 1)
            } else if let inherited = state.inheritedTartHome {
                if let inherited { setenv(tartHomeVariable, inherited, 1) } else { unsetenv(tartHomeVariable) }
                state.inheritedTartHome = nil
            }
        }
    }

    static let tartHomeVariable = "TART_HOME"

    /// The configured directory for `location`; nil = its default location.
    static func configuredDirectory(_ location: StorageLocation) -> URL? {
        current.path(for: location).map { URL(fileURLWithPath: $0, isDirectory: true) }
    }
}
