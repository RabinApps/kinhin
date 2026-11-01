import Foundation

extension KinhinConfig {
    public struct ContainerConfig: Sendable, Equatable {
        /// Defaults for an omitted `container.cpus` / `container.memory_gb` (shared by the initializer and the loader).
        public static let defaultCPUs = 4
        public static let defaultMemoryGB = 8

        /// Linux OCI image to run each runner container from (must be
        /// prepared with the runner agents via `kinhin image prepare`).
        public var image: String
        /// vCPUs per runner container.
        public var cpus: Int
        /// RAM (GB) per runner container.
        public var memoryGB: Int
        /// Image `kinhin image prepare --container` bakes on top of; nil uses
        /// `LinuxBaseImage.defaultReference`. Debian/Ubuntu-based images only.
        public var baseImage: String?

        public init(
            image: String, cpus: Int = defaultCPUs, memoryGB: Int = defaultMemoryGB, labels: [String]? = nil,
            baseImage: String? = nil, fleetLabels: Bool? = nil, minIdle: Int = 0, docker: Bool = false,
            flags: [String] = [], pools: [Pool] = []
        ) {
            self.image = image
            self.cpus = cpus
            self.memoryGB = memoryGB
            self.labels = labels
            self.baseImage = baseImage
            self.fleetLabels = fleetLabels
            self.minIdle = minIdle
            self.docker = docker
            self.flags = flags
            self.pools = pools
        }

        /// Extra labels the Apple-container pool's runners register with, so
        /// workflows can opt in per job (`runs-on: [kinhin-container]`).
        /// Always merged with "kinhin-container" at pool construction.
        public var labels: [String]?

        /// How the pool builds its base labels. nil/true (default): inherit the fleet `labels:`,
        /// with the `macos` OS label stripped (these guests run Linux). false: replace — the pool's
        /// labels come from `labels:` plus the "kinhin-container" marker alone.
        public var fleetLabels: Bool?

        /// Registered, idle runners this pool keeps at all times (`container.min_idle`); a busy runner does not
        /// count. 0 = off.
        public var minIdle: Int

        /// Docker inside each runner container (`container.docker`): the container starts with every Linux
        /// capability, and `dockerd` is started in it before the runner registers. The bake installs Docker when the
        /// base image lacks it.
        public var docker: Bool

        /// Extra `container run` arguments (`container.flags`), passed as separate argv elements after kinhin's own
        /// flags. The loader rejects the flags kinhin sets itself (`ConfigLoader.validatedContainerRunFlags`).
        public var flags: [String]

        /// The named pools (`container.pools:`), sorted by name, each with the keys above filled in where it leaves
        /// one out. Empty: the section itself is the one pool, exactly as before pools existed. Read the pools
        /// through `effectivePools`, which covers both shapes.
        public var pools: [Pool]

        enum CodingKeys: String, CodingKey {
            case image, cpus, labels
            case memoryGB = "memory_gb"
            case baseImage = "base_image"
            case fleetLabels = "fleet_labels"
            case minIdle = "min_idle"
            case docker, flags, pools
        }
    }
}
