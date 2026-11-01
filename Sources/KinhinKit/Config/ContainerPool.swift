import Foundation

extension KinhinConfig.ContainerConfig {
    /// One Linux runner pool on Apple container: a named `container.pools:` entry with the section's top-level keys
    /// filled in where it leaves one out, or, for a section without `pools:`, the section itself (`name` is then "").
    /// Everything that starts, sizes, routes, prepares or reports a container runner reads its pool from here.
    public struct Pool: Sendable, Equatable {
        /// The pool's name under `pools:`; "" for the section itself (no `pools:`).
        public var name: String
        /// Linux OCI image each runner container starts from.
        public var image: String
        /// What `kinhin image prepare --container` bakes `image` on; nil = `LinuxBaseImage.defaultReference`.
        public var baseImage: String?
        public var cpus: Int
        public var memoryGB: Int
        /// The pool's own labels: what a job's `runs-on:` must carry to land here (see `ContainerPoolRouting`).
        public var labels: [String]?
        /// See `ContainerConfig.fleetLabels`.
        public var fleetLabels: Bool?
        public var minIdle: Int
        public var docker: Bool
        public var flags: [String]
        /// At most this many of the pool's runners at once (`max:`); nil = only the shared budget and
        /// `max_runners` limit it. Only named pools have one.
        public var max: Int?

        public init(
            name: String, image: String, baseImage: String? = nil, cpus: Int = KinhinConfig.ContainerConfig.defaultCPUs,
            memoryGB: Int = KinhinConfig.ContainerConfig.defaultMemoryGB, labels: [String]? = nil,
            fleetLabels: Bool? = nil, minIdle: Int = 0,
            docker: Bool = false, flags: [String] = [], max: Int? = nil
        ) {
            self.name = name
            self.image = image
            self.baseImage = baseImage
            self.cpus = cpus
            self.memoryGB = memoryGB
            self.labels = labels
            self.fleetLabels = fleetLabels
            self.minIdle = minIdle
            self.docker = docker
            self.flags = flags
            self.max = max
        }

        /// The section without `pools:`, as its one unnamed pool.
        init(section: KinhinConfig.ContainerConfig) {
            self.init(
                name: "", image: section.image, baseImage: section.baseImage, cpus: section.cpus,
                memoryGB: section.memoryGB, labels: section.labels, fleetLabels: section.fleetLabels,
                minIdle: section.minIdle, docker: section.docker, flags: section.flags)
        }

        /// Whether this is a `pools:` entry rather than the section itself.
        public var isNamed: Bool { !name.isEmpty }

        /// The `runs-on:` label that targets this pool alone (`kinhin-container-<name>`); nil for the unnamed pool,
        /// whose runners register exactly as they did before pools existed.
        public var marker: String? { isNamed ? Self.marker(forName: name) : nil }

        public static func marker(forName name: String) -> String { "kinhin-container-\(name)" }

        /// What a pool name may be: it becomes part of a runner label (`kinhin-container-<name>`) and of a GitHub
        /// scale-set name, so lowercase letters, digits and inner hyphens only, like a DNS label, at most 32
        /// characters. Lowercase only, because the forges compare labels without case.
        public static func isValidName(_ name: String) -> Bool {
            name.count <= 32 && name.range(of: "^[a-z0-9]([a-z0-9-]*[a-z0-9])?$", options: .regularExpression) != nil
        }
    }

    /// Every pool the section runs: the named `pools:`, or the section itself as its one unnamed pool.
    public var effectivePools: [Pool] { pools.isEmpty ? [Pool(section: self)] : pools }

    /// The pool that serves container jobs no pool's labels claim, and the instances whose pool is unknown (adopted
    /// without a record, or from a pool since removed): the one with the fewest labels, then the first by name. With
    /// no `pools:`, the section itself.
    public var defaultPool: Pool { Self.defaultPool(of: effectivePools) ?? Pool(section: self) }

    /// The default pool among `pools` (see `defaultPool`); nil when there are none.
    static func defaultPool(of pools: [Pool]) -> Pool? {
        pools.min { ($0.labels?.count ?? 0, $0.name) < ($1.labels?.count ?? 0, $1.name) }
    }

    /// The pool `name` resolves to: that named pool, else the default pool ("" and names no longer configured).
    public func pool(named name: String?) -> Pool {
        pools.first { $0.name == name } ?? defaultPool
    }

    /// The images the pools run, each once, in pool order: what `kinhin image prepare` bakes and `image prune` keeps.
    public var poolImages: [String] {
        var seen = Set<String>()
        return effectivePools.map(\.image).filter { seen.insert($0).inserted }
    }

    /// The named pools whose image is not among `listed` (local Apple container image names, as `container image
    /// list` prints them; `x` matches `x:latest` and every tag of `x`). What the engine leaves out of the plan and
    /// the app marks "not built"; empty for a section without `pools:`.
    public func poolsMissingImage(listed: [String]) -> [Pool] {
        pools.filter { pool in !listed.contains { ImageInventory.ociMatches(name: $0, wanted: pool.image) } }
    }

    // MARK: - Baking a pool's image

    /// Whether the bake of `image` installs Docker: some named pool that runs it has `docker: true`. An image no
    /// named pool runs (and every image of a section without `pools:`) follows the section's own `docker`, as before
    /// pools. A shared image is baked once, so a pool without Docker that shares it simply never starts dockerd.
    public func bakesDocker(image: String) -> Bool {
        let running = pools.filter { $0.image == image }
        return running.isEmpty ? docker : running.contains(where: \.docker)
    }

    /// What `image` is baked on: the `base_image` of the named pools that run it (the loader keeps it to one), else
    /// the section's own.
    public func baseImage(forImage image: String) -> String? {
        pools.first { $0.image == image }.map(\.baseImage) ?? baseImage
    }
}
