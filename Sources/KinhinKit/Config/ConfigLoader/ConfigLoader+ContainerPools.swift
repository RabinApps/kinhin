import Foundation

// MARK: - Named Apple container pools (container.pools)

extension ConfigLoader {
    /// `container:` with a `pools:` map whose top level names no `image:`: the top-level keys are checked as usual,
    /// with an image every pool must then name for itself.
    static func parseContainerPools(_ container: PartialConfig.PartialContainer) throws -> KinhinConfig.ContainerConfig
    {
        var withoutPools = container
        withoutPools.pools = nil
        // A placeholder image that never reaches a pool: each pool must name its own (checked below).
        withoutPools.image = "kinhin-ci-linux"
        var section = try parseContainer(withoutPools)
        section.pools = try parsedPools(container, defaults: section, defaultImage: nil)
        section.image = section.defaultPool.image
        return section
    }

    /// `section` (the parsed top-level keys) with the pools of `container.pools`, each filled in from it.
    static func parseContainerPools(
        _ container: PartialConfig.PartialContainer, section: KinhinConfig.ContainerConfig
    ) throws -> KinhinConfig.ContainerConfig {
        var section = section
        section.pools = try parsedPools(container, defaults: section, defaultImage: section.image)
        return section
    }

    /// Every pool of `container.pools`, sorted by name: each key a pool leaves out comes from `defaults` (the
    /// section's top-level keys), and every value is checked as the same key on `container:` is, under the pool's own
    /// key path. Across pools: no two with the same labels and platform (a job could not tell them apart), and no image
    /// baked from two different bases or for two platforms.
    private static func parsedPools(
        _ container: PartialConfig.PartialContainer, defaults: KinhinConfig.ContainerConfig, defaultImage: String?
    ) throws -> [KinhinConfig.ContainerConfig.Pool] {
        guard let entries = container.pools, !entries.isEmpty else {
            throw ConfigError.invalid(
                "container.pools must name at least one pool (remove it to run the container: section as one pool)")
        }
        var pools: [KinhinConfig.ContainerConfig.Pool] = []
        for name in entries.keys.sorted() {
            guard let entry = entries[name] else { continue }
            pools.append(try parsedPool(name: name, entry, defaults: defaults, defaultImage: defaultImage))
        }
        struct LabelSet: Hashable {
            let labels: Set<String>
            let platform: LinuxPlatform
        }
        var labelSets: [LabelSet: String] = [:]
        var bakes: [String: (pool: String, base: String?, platform: LinuxPlatform)] = [:]
        for pool in pools {
            // `runner` and `runner:latest` are one baked image, so they must agree on base and platform too.
            let bakeKey = ImageInventory.ociRunnableReference(pool.image)
            let own = LabelSet(labels: Set((pool.labels ?? []).map { $0.lowercased() }), platform: pool.platform)
            if let other = labelSets[own] {
                throw ConfigError.invalid(
                    "container.pools \(other) and \(pool.name) have the same labels and platform, so jobs could not tell "
                        + "them apart (give each pool a label of its own)")
            }
            labelSets[own] = pool.name
            if let other = bakes[bakeKey], other.base != pool.baseImage {
                throw ConfigError.invalid(
                    "container.pools \(other.pool) and \(pool.name) both run image \(pool.image) but name different "
                        + "base_image values; one image is baked from one base")
            }
            if let other = bakes[bakeKey], other.platform != pool.platform {
                throw ConfigError.invalid(
                    "container.pools \(other.pool) and \(pool.name) both run image \(pool.image) but for different "
                        + "platforms; one image is baked for one platform (give the \(pool.platform.rawValue) pool an "
                        + "image of its own)")
            }
            bakes[bakeKey] = (pool.name, pool.baseImage, pool.platform)
        }
        return pools
    }

    private static func parsedPool(
        name: String, _ entry: PartialConfig.PartialContainerPool, defaults: KinhinConfig.ContainerConfig,
        defaultImage: String?
    ) throws -> KinhinConfig.ContainerConfig.Pool {
        let key = "container.pools.\(name)"
        guard KinhinConfig.ContainerConfig.Pool.isValidName(name) else {
            throw ConfigError.invalid(
                "container.pools: '\(name)' is not a valid pool name: use lowercase letters, digits and '-', starting "
                    + "and ending with a letter or digit, at most 32 characters (it becomes the runner label "
                    + "kinhin-container-<name>)")
        }
        guard let image = entry.image ?? defaultImage, !image.isEmpty else {
            throw ConfigError.invalid("\(key).image is required when container.image is not set")
        }
        try requireSafeImageReference(image, key: "\(key).image")
        if let cpus = entry.cpus, cpus < 1 { throw ConfigError.invalid("\(key).cpus must be >= 1") }
        if let mem = entry.memoryGB, mem < 2 { throw ConfigError.invalid("\(key).memory_gb must be >= 2") }
        let platform = try parsedContainerPlatform(entry.platform, key: "\(key).platform") ?? defaults.platform
        if let labels = entry.labels, labels.contains(where: { $0.trimmingCharacters(in: .whitespaces).isEmpty }) {
            throw ConfigError.invalid("\(key).labels must not contain empty labels")
        }
        let minIdle = entry.minIdle ?? defaults.minIdle
        if minIdle < 0 { throw ConfigError.invalid("\(key).min_idle must be >= 0") }
        if let max = entry.max {
            guard max >= 1 else { throw ConfigError.invalid("\(key).max must be >= 1") }
            guard minIdle <= max else {
                throw ConfigError.invalid("\(key).min_idle (\(minIdle)) must be <= \(key).max (\(max))")
            }
        }
        let base =
            try entry.baseImage.map { try validatedBaseImage($0, key: "\(key).base_image") } ?? defaults.baseImage
        let flags = try entry.flags.map { try validatedContainerRunFlags($0, key: "\(key).flags") } ?? defaults.flags
        return KinhinConfig.ContainerConfig.Pool(
            name: name, image: image, baseImage: base, cpus: entry.cpus ?? defaults.cpus,
            memoryGB: entry.memoryGB ?? defaults.memoryGB, labels: entry.labels ?? defaults.labels,
            fleetLabels: entry.fleetLabels ?? defaults.fleetLabels, minIdle: minIdle,
            docker: entry.docker ?? defaults.docker, flags: flags, max: entry.max, platform: platform)
    }
}
