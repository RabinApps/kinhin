import Foundation

/// Adds, edits and removes the named Apple container pools (`container.pools:`) for the app's Routing page. Each
/// edit changes the editor snapshot's `container.pools` and writes the whole `container:` section back through
/// `GeneralConfigEditor` (the same rewrite a base image change makes): everything outside `container:` keeps its
/// comments and formatting, every other pool and section key is written back as it was, and nothing is written
/// unless the whole file still passes `ConfigLoader.parse`.
public enum ContainerPoolsConfigEditor {
    public typealias Pool = GeneralConfigEditor.Snapshot.ContainerPool
    public typealias Container = GeneralConfigEditor.Snapshot.Container

    // MARK: - Writing

    /// Writes `pool`: a new entry when `original` is nil, else in place of the pool named `original` (a rename
    /// when the names differ). Returns the written text.
    @discardableResult
    public static func save(_ pool: Pool, replacing original: String?, at url: URL = Paths.config) throws -> String {
        let container = try currentContainer(at: url)
        return try GeneralConfigEditor.apply(.container(saving(pool, replacing: original, in: container)), to: url)
    }

    /// Removes the pool named `name`. Returns the written text.
    @discardableResult
    public static func remove(named name: String, at url: URL = Paths.config) throws -> String {
        let container = try currentContainer(at: url)
        return try GeneralConfigEditor.apply(.container(removing(name, from: container)), to: url)
    }

    // MARK: - The edit itself (pure, for tests)

    /// `container` with `pool` added, or put in place of the pool named `original`. The name must be label-safe
    /// (`Pool.isValidName`) and not taken by another pool; everything else is left to the loader.
    static func saving(_ pool: Pool, replacing original: String?, in container: Container) throws -> Container {
        guard KinhinConfig.ContainerConfig.Pool.isValidName(pool.name) else {
            throw ConfigEditError.validation(
                "pool name '\(pool.name)' must be lowercase letters, digits and inner '-', at most 32 characters "
                    + "(it becomes the label kinhin-container-<name>)")
        }
        var updated = container
        if let original {
            guard updated.pools.contains(where: { $0.name == original }) else {
                throw ConfigEditError.unsupported("no container pool named '\(original)' in config.yaml")
            }
            updated.pools.removeAll { $0.name == original }
        }
        guard !updated.pools.contains(where: { $0.name == pool.name }) else {
            throw ConfigEditError.validation("a container pool named '\(pool.name)' already exists")
        }
        updated.pools.append(pool)
        updated.pools.sort { $0.name < $1.name }
        return updated
    }

    /// `container` without the pool named `name`. Removing the last pool turns the section back into its one
    /// unnamed pool, which needs an image of its own: when the section has none, it takes the removed pool's image
    /// and the base image that image is baked from (the pool's own, else the section's), so the file keeps a
    /// runnable Linux pool that re-bakes the same image.
    static func removing(_ name: String, from container: Container) throws -> Container {
        guard let removed = container.pools.first(where: { $0.name == name }) else {
            throw ConfigEditError.unsupported("no container pool named '\(name)' in config.yaml")
        }
        var updated = container
        updated.pools.removeAll { $0.name == name }
        if updated.pools.isEmpty, updated.image.isEmpty {
            updated.image = removed.image ?? "kinhin-ci-linux"
            if let base = removed.baseImage { updated.baseImage = base }
        }
        return updated
    }

    // MARK: - Reading

    private static func currentContainer(at url: URL) throws -> Container {
        guard let snapshot = try ConfigStore.snapshot(at: url) else { throw ConfigEditError.notFound(url.path) }
        guard let container = snapshot.container else {
            throw ConfigEditError.unsupported("Apple container isn't enabled in config.yaml")
        }
        return container
    }
}
