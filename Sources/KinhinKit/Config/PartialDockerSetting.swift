import Foundation

extension PartialConfig {
    /// `docker:` on `container:` and on a `container.pools:` entry: `true` / `false`, or a mapping that turns Docker on
    /// with options (`{ cache: false }`: Docker on, the Docker Hub cache off; `{ build_cache: true }`: each runner's
    /// Docker state kept between jobs). A mapping always means Docker on, so `docker: {}` is the same as `docker: true`.
    struct PartialDockerSetting: Decodable, Equatable {
        /// Docker inside each runner container.
        var enabled: Bool
        /// The Docker Hub pull-through cache (`DockerRegistryCache`); nil = the default, on.
        var cache: Bool?
        /// A persistent Docker volume per runner (`DockerBuildCacheVolumes`); nil = the default, off.
        var buildCache: Bool?

        enum CodingKeys: String, CodingKey, CaseIterable {
            case cache
            case buildCache = "build_cache"
        }

        init(enabled: Bool, cache: Bool? = nil, buildCache: Bool? = nil) {
            self.enabled = enabled
            self.cache = cache
            self.buildCache = buildCache
        }

        init(from decoder: Decoder) throws {
            let single = try decoder.singleValueContainer()
            if let flag = try? single.decode(Bool.self) {  // not a Bool: try the mapping form below
                self.init(enabled: flag)
                return
            }
            // Neither a Bool nor a mapping: the error below names both forms, which says more than either failure.
            guard let options = try? decoder.container(keyedBy: CodingKeys.self) else {
                throw DecodingError.dataCorruptedError(
                    in: single, debugDescription: "must be true, false or a mapping such as { cache: false }")
            }
            self.init(
                enabled: true, cache: try options.decodeIfPresent(Bool.self, forKey: .cache),
                buildCache: try options.decodeIfPresent(Bool.self, forKey: .buildCache))
        }
    }
}
