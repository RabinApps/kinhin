import Foundation

// MARK: - tart_home, container_app_root, registry_cache_path, toolchain_cache_path

extension ConfigLoader {
    /// The four storage keys. Each must be an absolute, normalized directory path; no two may be the same directory,
    /// and none may sit inside another (Tart and Apple container each own their whole tree). Whether the volume is
    /// mounted is not checked here: a config must parse on a Mac whose external disk is unplugged right now.
    /// `StoragePreflight` checks that before anything starts.
    static func parseStorage(_ partial: PartialConfig) throws -> KinhinConfig.StorageConfig {
        var storage = KinhinConfig.StorageConfig()
        storage.tartHome = try partial.tartHome.map { try storagePath($0, key: StorageLocation.tartHome.configKey) }
        storage.containerAppRoot = try partial.containerAppRoot.map {
            try storagePath($0, key: StorageLocation.containerAppRoot.configKey)
        }
        storage.registryCachePath = try partial.registryCachePath.map {
            try storagePath($0, key: StorageLocation.registryCache.configKey)
        }
        storage.toolchainCachePath = try partial.toolchainCachePath.map {
            try storagePath($0, key: StorageLocation.toolchainCache.configKey)
        }
        let configured = storage.configured
        for (index, first) in configured.enumerated() {
            for second in configured.dropFirst(index + 1) {
                if first.path == second.path {
                    throw ConfigError.invalid(
                        "\(first.location.configKey) and \(second.location.configKey) are the same directory "
                            + "(\(first.path)); give each its own directory")
                }
                if let pair = nested(first, second) {
                    let (outer, inner) = pair
                    throw ConfigError.invalid(
                        "\(inner.location.configKey) (\(inner.path)) is inside \(outer.location.configKey) "
                            + "(\(outer.path)); give each its own sibling directory under \(parentPath(outer.path))")
                }
            }
        }
        return storage
    }

    /// The pair ordered (outer, inner) when one path is inside the other; nil when neither is.
    private static func nested(
        _ a: (location: StorageLocation, path: String), _ b: (location: StorageLocation, path: String)
    ) -> ((location: StorageLocation, path: String), (location: StorageLocation, path: String))? {
        if b.path.hasPrefix(a.path + "/") { return (a, b) }
        if a.path.hasPrefix(b.path + "/") { return (b, a) }
        return nil
    }

    /// `path`'s parent with a trailing slash, for the sibling suggestion.
    private static func parentPath(_ path: String) -> String {
        let parent = (path as NSString).deletingLastPathComponent
        return parent == "/" ? "/" : parent + "/"
    }

    /// Validates one storage path and returns it without a trailing slash. Relative paths and `~` are rejected
    /// rather than resolved: the daemon runs under launchd, whose working directory and environment differ from the
    /// shell the config was written in.
    static func storagePath(_ raw: String, key: String) throws -> String {
        let path = raw.trimmingCharacters(in: .whitespaces)
        guard !path.isEmpty else {
            throw ConfigError.invalid("\(key) must not be empty (remove the key to use the default location)")
        }
        guard !path.contains(where: { $0.isNewline || $0 == "\0" }) else {
            throw ConfigError.invalid("\(key) must be a single-line path")
        }
        if path.hasPrefix("~") {
            throw ConfigError.invalid("\(key) must be an absolute path; write the home folder out (\(key): /Users/…)")
        }
        guard path.hasPrefix("/") else {
            throw ConfigError.invalid("\(key) must be an absolute path starting with /, got '\(path)'")
        }
        let components = path.split(separator: "/", omittingEmptySubsequences: true)
        guard !components.contains(where: { $0 == "." || $0 == ".." }) else {
            throw ConfigError.invalid("\(key) must not contain '.' or '..' components, got '\(path)'")
        }
        guard !components.isEmpty else {
            throw ConfigError.invalid("\(key) must not be the root directory /")
        }
        if components.count == 2, components[0] == "Volumes" {
            let suggestion = "/Volumes/\(components[1])/<folder>"
            throw ConfigError.invalid(
                "\(key) must be a directory on the volume, not the volume itself; use \(suggestion)")
        }
        return "/" + components.joined(separator: "/")
    }
}
