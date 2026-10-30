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
            baseImage: String? = nil, fleetLabels: Bool? = nil
        ) {
            self.image = image
            self.cpus = cpus
            self.memoryGB = memoryGB
            self.labels = labels
            self.baseImage = baseImage
            self.fleetLabels = fleetLabels
        }

        /// Extra labels the Apple-container pool's runners register with, so
        /// workflows can opt in per job (`runs-on: [kinhin-container]`).
        /// Always merged with "kinhin-container" at pool construction.
        public var labels: [String]?

        /// How the pool builds its base labels. nil/true (default): inherit the fleet `labels:`,
        /// with the `macos` OS label stripped (these guests run Linux). false: replace — the pool's
        /// labels come from `labels:` plus the "kinhin-container" marker alone.
        public var fleetLabels: Bool?

        enum CodingKeys: String, CodingKey {
            case image, cpus, labels
            case memoryGB = "memory_gb"
            case baseImage = "base_image"
            case fleetLabels = "fleet_labels"
        }
    }
}
