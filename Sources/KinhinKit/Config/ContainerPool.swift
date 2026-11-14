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
        /// See `ContainerConfig.dockerCache`.
        public var dockerCache: Bool
        public var flags: [String]
        /// At most this many of the pool's runners at once (`max:`); nil = only the shared budget and
        /// `max_runners` limit it. Only named pools have one.
        public var max: Int?
        /// See `ContainerConfig.platform`.
        public var platform: LinuxPlatform
        /// Whether the pool takes jobs (`enabled:`, and the section's own `enabled:` for every pool). A disabled pool
        /// keeps its settings but is out of routing, scheduling and the Fleet page; its running instances drain.
        public var enabled: Bool

        public init(
            name: String, image: String, baseImage: String? = nil, cpus: Int = KinhinConfig.ContainerConfig.defaultCPUs,
            memoryGB: Int = KinhinConfig.ContainerConfig.defaultMemoryGB, labels: [String]? = nil,
            fleetLabels: Bool? = nil, minIdle: Int = 0,
            docker: Bool = false, dockerCache: Bool = true, flags: [String] = [], max: Int? = nil,
            platform: LinuxPlatform = .arm64, enabled: Bool = true
        ) {
            self.enabled = enabled
            self.name = name
            self.image = image
            self.baseImage = baseImage
            self.cpus = cpus
            self.memoryGB = memoryGB
            self.labels = labels
            self.fleetLabels = fleetLabels
            self.minIdle = minIdle
            self.docker = docker
            self.dockerCache = dockerCache
            self.flags = flags
            self.max = max
            self.platform = platform
        }

        /// The section without `pools:`, as its one unnamed pool.
        init(section: KinhinConfig.ContainerConfig) {
            self.init(
                name: "", image: section.image, baseImage: section.baseImage, cpus: section.cpus,
                memoryGB: section.memoryGB, labels: section.labels, fleetLabels: section.fleetLabels,
                minIdle: section.minIdle, docker: section.docker, dockerCache: section.dockerCache,
                flags: section.flags,
                platform: section.platform, enabled: section.enabled)
        }

        /// Whether the pool's runners pull through the Docker Hub cache: Docker on, and the cache not turned off.
        public var usesDockerCache: Bool { docker && dockerCache }

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
            // `\z`, not `$`: `$` also matches before a trailing newline, which would let "a\n" through.
            name.count <= 32 && name.range(of: "^[a-z0-9]([a-z0-9-]*[a-z0-9])?\\z", options: .regularExpression) != nil
        }
    }

    /// Every pool the section runs: the named `pools:`, or the section itself as its one unnamed pool.
    public var effectivePools: [Pool] { pools.isEmpty ? [Pool(section: self)] : pools }

    /// The images the enabled pools run, each once: what readiness checks and `image list` expect to be present.
    public var enabledPoolImages: [String] {
        var seen = Set<String>()
        return enabledPools.map(\.image).filter { seen.insert($0).inserted }
    }

    /// The pools that take jobs: `effectivePools` without the disabled ones. Routing, scheduling, scale sets and
    /// the Fleet page read this; image prepare/prune keep reading `effectivePools`, so a disabled pool's image stays.
    public var enabledPools: [Pool] { effectivePools.filter(\.enabled) }

    /// Whether any pool pulls through the Docker Hub cache, so kinhin runs it (and doctor and `image prune` know it).
    public var usesDockerCache: Bool { effectivePools.contains(where: \.usesDockerCache) }

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
    /// list` prints them): the exact reference, or `x:latest` for an untagged `x`, the tag `container run` starts
    /// from (`ImageInventory.ociUses`). Another tag of `x` does not count, since the runner could not start from it.
    /// What the engine leaves out of the plan, doctor reports and the app marks "not built"; empty for a section
    /// without `pools:`.
    public func poolsMissingImage(listed: [String]) -> [Pool] {
        pools.filter { pool in !listed.contains { ImageInventory.ociUses(name: $0, wanted: pool.image) } }
    }

    // MARK: - Baking a pool's image

    /// The named pools that run `image`, compared by the tag a runner starts (`runner` and `runner:latest` are the one
    /// image a bake writes).
    func pools(running image: String) -> [Pool] {
        let runnable = ImageInventory.ociRunnableReference(image)
        return pools.filter { ImageInventory.ociRunnableReference($0.image) == runnable }
    }

    /// Whether the bake of `image` installs Docker: some named pool that runs it has `docker: true`. An image no
    /// named pool runs (and every image of a section without `pools:`) follows the section's own `docker`, as before
    /// pools. A shared image is baked once, so a pool without Docker that shares it simply never starts dockerd.
    public func bakesDocker(image: String) -> Bool {
        let running = pools(running: image)
        return running.isEmpty ? docker : running.contains(where: \.docker)
    }

    /// What `image` is baked on: the `base_image` of the named pools that run it (the loader keeps it to one), else
    /// the section's own.
    public func baseImage(forImage image: String) -> String? {
        pools(running: image).first.map(\.baseImage) ?? baseImage
    }

    /// The architecture `image` is baked for: the `platform` of the named pools that run it (the loader keeps it to
    /// one), else the section's own.
    public func platform(forImage image: String) -> LinuxPlatform {
        pools(running: image).first?.platform ?? platform
    }
}
