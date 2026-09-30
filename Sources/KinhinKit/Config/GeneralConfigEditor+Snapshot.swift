import Foundation
import Yams

// MARK: - Snapshot (the editable subset)

extension GeneralConfigEditor {
    /// The typed subset the UI edits, decoded from the raw YAML.
    public struct Snapshot: Equatable, Sendable {
        public var labels: [String]
        public var minRunners: Int
        public var maxRunners: Int
        public var runnersPerVM: Int
        public var pollInterval: Int
        public var autoResume: Bool
        public var vmCPU: Int
        public var vmMemoryGB: Int
        public var vmEphemeral: Bool
        public var image: String
        /// What the tart prepare starts from (nil = default macOS base).
        public var tartBaseImage: String?
        public var reserveCPU: Int
        public var reserveMemoryGB: Int
        public var container: Container?
        public var docker: Docker?

        /// The configured base image for a Linux runtime (nil = default).
        /// The configured Docker platform (arm64 when absent or unrecognized).
        public var dockerPlatform: LinuxPlatform {
            docker?.platform.flatMap { LinuxPlatform(configValue: $0) } ?? .arm64
        }

        public func baseImage(for runtime: RuntimeID) -> String? {
            switch runtime {
            case .tart: return tartBaseImage
            case .appleContainer: return container?.baseImage
            case .docker: return docker?.baseImage
            default: return nil
            }
        }

        public struct Container: Equatable, Sendable {
            public var image: String
            public var cpus: Int
            public var memoryGB: Int
            /// See `KinhinConfig.ContainerConfig.baseImage` / `.labels`; carried so a
            /// section rewrite doesn't drop them.
            public var baseImage: String?
            public var labels: [String]?
            public init(
                image: String, cpus: Int, memoryGB: Int, baseImage: String? = nil, labels: [String]? = nil
            ) {
                self.image = image
                self.cpus = cpus
                self.memoryGB = memoryGB
                self.baseImage = baseImage
                self.labels = labels
            }
        }

        public struct Docker: Equatable, Sendable {
            public var image: String
            public var cpus: Int
            public var memoryGB: Int
            public var maxSlots: Int
            public var baseImage: String?
            /// Raw `docker.platform:` value, carried so a rewrite of the section keeps it.
            public var platform: String?
            public init(
                image: String, cpus: Int, memoryGB: Int, maxSlots: Int, baseImage: String? = nil,
                platform: String? = nil
            ) {
                self.image = image
                self.cpus = cpus
                self.memoryGB = memoryGB
                self.maxSlots = maxSlots
                self.baseImage = baseImage
                self.platform = platform
            }
        }
    }

    /// Decode the editable subset from config text (defaults filled from
    /// `KinhinConfig.default` where the key is absent). Throws when the text
    /// is not valid YAML at all — callers surface that instead of editing
    /// against a phantom snapshot.
    public static func snapshot(from yaml: String) throws -> Snapshot {
        let root: Node?
        do {
            root = try Yams.compose(yaml: yaml)
        } catch {
            throw ConfigEditError.yamlParse(error.localizedDescription)
        }
        guard let root, root.mapping != nil else {
            throw ConfigEditError.yamlParse("top level must be a mapping")
        }
        let partial: PartialConfig
        do {
            partial = try YAMLDecoder().decode(PartialConfig.self, from: yaml)
        } catch {
            throw ConfigEditError.decoding(error)
        }
        let d = KinhinConfig.default
        let vm = partial.vm
        let reserve = partial.reserve
        return Snapshot(
            labels: partial.labels ?? d.labels,
            minRunners: partial.minRunners ?? d.minRunners,
            maxRunners: partial.maxRunners ?? d.maxRunners,
            runnersPerVM: partial.runnersPerVM ?? d.runnersPerVM,
            pollInterval: partial.pollInterval ?? d.pollInterval,
            autoResume: partial.autoResume ?? d.autoResume,
            vmCPU: vm?.cpu ?? d.vm.cpuCount,
            vmMemoryGB: vm?.memoryGB ?? d.vm.memoryGB,
            vmEphemeral: vm?.ephemeral ?? d.vm.ephemeral,
            image: partial.image ?? d.image,
            tartBaseImage: partial.baseImage,
            reserveCPU: reserve?.cpu ?? d.reserve.cpu,
            reserveMemoryGB: reserve?.memoryGB ?? d.reserve.memoryGB,
            container: partial.container.map {
                .init(
                    image: $0.image ?? "kinhin-ci-linux", cpus: $0.cpus ?? 4, memoryGB: $0.memoryGB ?? 8,
                    baseImage: $0.baseImage, labels: $0.labels)
            },
            docker: partial.docker.map {
                .init(
                    image: $0.image ?? "kinhin-ci-linux", cpus: $0.cpus ?? 2, memoryGB: $0.memoryGB ?? 4,
                    maxSlots: $0.maxSlots ?? 8, baseImage: $0.baseImage, platform: $0.platform)
            }
        )
    }
}
