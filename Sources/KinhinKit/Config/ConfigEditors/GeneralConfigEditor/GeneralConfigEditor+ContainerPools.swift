import Foundation

// MARK: - container.pools in the editable snapshot

extension GeneralConfigEditor.Snapshot {
    /// One `container.pools:` entry exactly as written: only the keys the file sets, so a rewrite of the `container:`
    /// section (a base image change, the section toggle) writes each pool back unchanged instead of baking the
    /// section's defaults into it. The app has no pools editor; it only carries them.
    public struct ContainerPool: Equatable, Sendable {
        public var name: String
        public var image: String?
        public var baseImage: String?
        public var cpus: Int?
        public var memoryGB: Int?
        public var labels: [String]?
        public var fleetLabels: Bool?
        public var minIdle: Int?
        public var docker: Bool?
        /// false for `docker: { cache: false }`; nil otherwise (the cache's default, on). Written only with `docker`
        /// true, so the app's pool sheet carries it like `fleetLabels`.
        public var dockerCache: Bool?
        public var flags: [String]?
        public var max: Int?
        public var platform: String?

        public init(
            name: String, image: String? = nil, baseImage: String? = nil, cpus: Int? = nil, memoryGB: Int? = nil,
            labels: [String]? = nil, fleetLabels: Bool? = nil, minIdle: Int? = nil, docker: Bool? = nil,
            dockerCache: Bool? = nil, flags: [String]? = nil, max: Int? = nil, platform: String? = nil
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
            self.dockerCache = dockerCache
            self.flags = flags
            self.max = max
            self.platform = platform
        }

        /// The decoded `pools:` map as entries sorted by name (the loader's order).
        static func pools(from partial: [String: PartialConfig.PartialContainerPool]?) -> [ContainerPool] {
            (partial ?? [:]).sorted { $0.key < $1.key }.map { name, entry in
                ContainerPool(
                    name: name, image: entry.image, baseImage: entry.baseImage, cpus: entry.cpus,
                    memoryGB: entry.memoryGB, labels: entry.labels, fleetLabels: entry.fleetLabels,
                    minIdle: entry.minIdle, docker: entry.docker?.enabled,
                    // `{ cache: true }` is the default spelled out: kept as nil, so a rewrite writes `docker: true`.
                    dockerCache: entry.docker?.cache == false ? false : nil, flags: entry.flags, max: entry.max,
                    platform: entry.platform)
            }
        }

        /// The entry as block YAML under `pools:`, one key per line, each `indent` deep (its keys two more). A pool
        /// that sets nothing is written as an empty mapping, so it stays a pool.
        func lines(indent: String) -> [String] {
            let key = indent + "  "
            func list(_ values: [String]) -> String { "[\(values.map(YAMLText.quoted).joined(separator: ", "))]" }
            var body: [String] = []
            if let image { body.append("\(key)image: \(YAMLText.quoted(image))") }
            if let baseImage { body.append("\(key)base_image: \(YAMLText.quoted(baseImage))") }
            if let cpus { body.append("\(key)cpus: \(cpus)") }
            if let memoryGB { body.append("\(key)memory_gb: \(memoryGB)") }
            if let labels { body.append("\(key)labels: \(list(labels))") }
            if let fleetLabels { body.append("\(key)fleet_labels: \(fleetLabels)") }
            if let minIdle { body.append("\(key)min_idle: \(minIdle)") }
            if let docker {
                let value = docker ? GeneralConfigEditor.dockerValue(cache: dockerCache ?? true) : "false"
                body.append("\(key)docker: \(value)")
            }
            if let flags { body.append("\(key)flags: \(list(flags))") }
            if let max { body.append("\(key)max: \(max)") }
            if let platform { body.append("\(key)platform: \(YAMLText.quoted(platform))") }
            return body.isEmpty ? ["\(indent)\(name): {}"] : ["\(indent)\(name):"] + body
        }
    }
}
