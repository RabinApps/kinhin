import Foundation

extension KinhinConfig {
    /// Docker runtime settings. `max_slots` bounds the container slots this
    /// fleet may run (capacity is also bounded by the host budget partition
    /// like every other runtime).
    public struct DockerForgeConfig: Sendable, Equatable {
        /// Defaults for omitted `docker.cpus` / `memory_gb` / `max_slots` (shared by the initializer and the loader).
        public static let defaultCPUs = 2
        public static let defaultMemoryGB = 4
        public static let defaultMaxSlots = 8

        /// Linux OCI image baked with the runner agents (kinhin image
        /// prepare --docker).
        public var image: String
        /// vCPUs per runner container.
        public var cpus: Int
        /// RAM (GB) per runner container.
        public var memoryGB: Int
        /// Hard upper bound on concurrent container slots.
        public var maxSlots: Int
        /// Image `kinhin image prepare --docker` bakes on top of; nil uses
        /// `LinuxBaseImage.defaultReference`. Debian/Ubuntu-based images only.
        public var baseImage: String?
        /// Container architecture. `linux/amd64` runs under emulation on
        /// Apple Silicon (see `LinuxPlatform.emulationNotice`).
        public var platform: LinuxPlatform

        public init(
            image: String, cpus: Int = defaultCPUs, memoryGB: Int = defaultMemoryGB, maxSlots: Int = defaultMaxSlots,
            baseImage: String? = nil,
            platform: LinuxPlatform = .arm64, fleetLabels: Bool? = nil
        ) {
            self.image = image
            self.cpus = cpus
            self.memoryGB = memoryGB
            self.maxSlots = maxSlots
            self.baseImage = baseImage
            self.platform = platform
            self.fleetLabels = fleetLabels
        }

        /// How the pool builds its base labels. nil/true (default): inherit the fleet `labels:`,
        /// with the `macos` OS label stripped (these guests run Linux). false: replace — the pool's
        /// labels come from the "kinhin-docker" marker (and the platform's arm64/x64) alone.
        public var fleetLabels: Bool?

        enum CodingKeys: String, CodingKey {
            case image, cpus, platform
            case memoryGB = "memory_gb"
            case maxSlots = "max_slots"
            case baseImage = "base_image"
            case fleetLabels = "fleet_labels"
        }
    }
}
