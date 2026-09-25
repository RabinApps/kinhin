import Foundation

/// Decode target mirroring KinhinConfig but with all fields optional so we
/// can produce precise validation errors instead of opaque decode failures.
/// Public because the toolchains validation entry (`parseToolchains`) takes
/// a `PartialToolchains` — the CLI's flag overrides reuse the same rules.
public struct PartialConfig: Decodable {
    var repo: String?
    var labels: [String]?
    var minRunners: Int?
    var maxRunners: Int?
    var runnersPerVM: Int?
    var pollInterval: Int?
    var tokenTTL: Int?
    var vm: PartialVM?
    var image: String?
    var vmBootTimeout: Int?
    var diskGB: Int?
    var tartPath: String?
    var reserve: PartialReserve?
    var gitea: PartialGitea?
    var container: PartialContainer?
    var docker: PartialDocker?
    var runtimes: PartialRuntimes?
    var provisionScript: String?
    var toolchains: PartialToolchains?

    struct PartialGitea: Decodable {
        var instance: String?
        var scope: String?
        var labels: [String]?
    }

    struct PartialVM: Decodable {
        var cpu: Int?
        var memoryGB: Int?
        var ephemeral: Bool?

        enum CodingKeys: String, CodingKey {
            case cpu
            case memoryGB = "memory_gb"
            case ephemeral
        }
    }

    struct PartialContainer: Decodable {
        var image: String?
        var cpus: Int?
        var memoryGB: Int?
        var labels: [String]?
        var baseImage: String?
        /// Only present so `container.platform` can be rejected with a clear message.
        var platform: String?

        enum CodingKeys: String, CodingKey {
            case image
            case cpus
            case memoryGB = "memory_gb"
            case labels
            case baseImage = "base_image"
            case platform
        }
    }

    struct PartialDocker: Decodable {
        var image: String?
        var cpus: Int?
        var memoryGB: Int?
        var maxSlots: Int?
        var baseImage: String?
        var platform: String?

        enum CodingKeys: String, CodingKey {
            case image
            case cpus
            case memoryGB = "memory_gb"
            case maxSlots = "max_slots"
            case baseImage = "base_image"
            case platform
        }
    }

    struct PartialRuntimes: Decodable {
        var `default`: String?
        var budget: [String: Double]?
        var routes: [PartialRoute]?
    }

    struct PartialRoute: Decodable {
        var pattern: String?
        var runtime: String?
    }

    struct PartialReserve: Decodable {
        var cpu: Int?
        var memoryGB: Int?

        enum CodingKeys: String, CodingKey {
            case cpu
            case memoryGB = "memory_gb"
        }
    }

    /// Public because `ConfigLoader.parseToolchains` (the shared validation
    /// entry the CLI uses for `--toolchain/--stack` overrides) exposes it.
    public struct PartialToolchains: Decodable {
        public var specs: [String]?
        public var brew: [String]?
        public var stacks: [String]?
        public var shareCache: Bool?
        public var cache: PartialCachePolicy?

        public init(
            specs: [String]? = nil, brew: [String]? = nil, stacks: [String]? = nil, shareCache: Bool? = nil,
            cache: PartialCachePolicy? = nil
        ) {
            self.specs = specs
            self.brew = brew
            self.stacks = stacks
            self.shareCache = shareCache
            self.cache = cache
        }

        enum CodingKeys: String, CodingKey {
            case specs
            case brew
            case stacks
            case shareCache = "share_cache"
            case cache
        }
    }

    public struct PartialCachePolicy: Decodable {
        public var autoPrune: Bool?
        public var maxAgeDays: Int?
        public var maxGB: Int?

        public init(autoPrune: Bool? = nil, maxAgeDays: Int? = nil, maxGB: Int? = nil) {
            self.autoPrune = autoPrune
            self.maxAgeDays = maxAgeDays
            self.maxGB = maxGB
        }

        enum CodingKeys: String, CodingKey {
            case autoPrune = "auto_prune"
            case maxAgeDays = "max_age_days"
            case maxGB = "max_gb"
        }
    }

    enum CodingKeys: String, CodingKey {
        case repo
        case labels
        case minRunners = "min_runners"
        case maxRunners = "max_runners"
        case runnersPerVM = "runners_per_vm"
        case pollInterval = "poll_interval"
        case tokenTTL = "token_ttl"
        case vm
        case image
        case vmBootTimeout = "vm_boot_timeout"
        case diskGB = "disk_gb"
        case tartPath = "tart_path"
        case reserve
        case gitea
        case container
        case docker
        case runtimes
        case provisionScript = "provision_script"
        case toolchains
    }
}
