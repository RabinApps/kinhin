import Foundation

extension KinhinConfig {
    /// Where the large trees live (`tart_home:`, `container_app_root:`, `registry_cache_path:`,
    /// `toolchain_cache_path:`). Every key is optional; an absent key keeps today's default location. A Mac whose
    /// internal disk is tight points them at an external volume, and kinhin then checks that volume before it starts
    /// anything that writes there (`StoragePreflight`).
    public struct StorageConfig: Sendable, Equatable {
        /// Tart's home (`TART_HOME`): VM bundles and the OCI cache. nil = `~/.tart`.
        public var tartHome: String?
        /// Apple container's app root (`container system start --app-root`): images, containers and kernels.
        /// nil = `~/Library/Application Support/com.apple.container`.
        public var containerAppRoot: String?
        /// The Docker Hub cache's data directory. nil = `Application Support/Kinhin/registry-cache`.
        public var registryCachePath: String?
        /// The shared toolchain download cache. nil = `Application Support/Kinhin/toolchain-cache`.
        public var toolchainCachePath: String?

        public init(
            tartHome: String? = nil, containerAppRoot: String? = nil, registryCachePath: String? = nil,
            toolchainCachePath: String? = nil
        ) {
            self.tartHome = tartHome
            self.containerAppRoot = containerAppRoot
            self.registryCachePath = registryCachePath
            self.toolchainCachePath = toolchainCachePath
        }

        /// The configured path for `location`; nil when that key is absent.
        public func path(for location: StorageLocation) -> String? {
            switch location {
            case .tartHome: return tartHome
            case .containerAppRoot: return containerAppRoot
            case .registryCache: return registryCachePath
            case .toolchainCache: return toolchainCachePath
            }
        }

        /// Every configured location with its path, in `StorageLocation` order.
        public var configured: [(location: StorageLocation, path: String)] {
            StorageLocation.allCases.compactMap { location in
                path(for: location).map { (location: location, path: $0) }
            }
        }

        /// True when no key is set: every tree stays at its default location.
        public var isEmpty: Bool { configured.isEmpty }
    }
}

/// One of the relocatable storage trees.
public enum StorageLocation: String, Sendable, CaseIterable, Codable {
    case tartHome
    case containerAppRoot
    case registryCache
    case toolchainCache

    /// The `config.yaml` key that sets it.
    public var configKey: String {
        switch self {
        case .tartHome: return "tart_home"
        case .containerAppRoot: return "container_app_root"
        case .registryCache: return "registry_cache_path"
        case .toolchainCache: return "toolchain_cache_path"
        }
    }

    /// What lives there, for messages.
    var title: String {
        switch self {
        case .tartHome: return "Tart home"
        case .containerAppRoot: return "Apple container app root"
        case .registryCache: return "Docker Hub cache"
        case .toolchainCache: return "toolchain cache"
        }
    }
}
