import Foundation

extension KinhinConfig {
    /// Docker runtime settings. `max_slots` bounds the container slots this
    /// fleet may run (capacity is also bounded by the host budget partition
    /// like every other runtime).
    public struct DockerForgeConfig: Sendable, Equatable {
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
            image: String, cpus: Int = 2, memoryGB: Int = 4, maxSlots: Int = 8, baseImage: String? = nil,
            platform: LinuxPlatform = .arm64
        ) {
            self.image = image
            self.cpus = cpus
            self.memoryGB = memoryGB
            self.maxSlots = maxSlots
            self.baseImage = baseImage
            self.platform = platform
        }

        enum CodingKeys: String, CodingKey {
            case image, cpus, platform
            case memoryGB = "memory_gb"
            case maxSlots = "max_slots"
            case baseImage = "base_image"
        }
    }
}
