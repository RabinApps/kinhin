import Foundation

extension KinhinConfig {
    public struct ContainerConfig: Sendable, Equatable {
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
            image: String, cpus: Int = 4, memoryGB: Int = 8, labels: [String]? = nil, baseImage: String? = nil
        ) {
            self.image = image
            self.cpus = cpus
            self.memoryGB = memoryGB
            self.labels = labels
            self.baseImage = baseImage
        }

        /// Extra labels the Apple-container pool's runners register with, so
        /// workflows can opt in per job (`runs-on: [kinhin-container]`).
        /// Always merged with "kinhin-container" at pool construction.
        public var labels: [String]?

        enum CodingKeys: String, CodingKey {
            case image, cpus, labels
            case memoryGB = "memory_gb"
            case baseImage = "base_image"
        }
    }
}
