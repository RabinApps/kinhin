import Foundation

/// Decode target mirroring KinhinConfig but with all fields optional so we
/// can produce precise validation errors instead of opaque decode failures.
/// Public because the toolchains validation entry (`parseToolchains`) takes
/// a `PartialToolchains` — the CLI's flag overrides reuse the same rules.
public struct PartialConfig: Decodable {
    /// Removed keys: decoded only so the loader can reject them with a
    /// pointer to the accounts: replacement instead of a silent ignore.
    var repo: String?
    var gitea: PartialGitea?
    var forgejo: PartialGitea?
    var labels: [String]?
    var minRunners: Int?
    var maxRunners: Int?
    var runnersPerVM: Int?
    var pollInterval: Int?
    var autoResume: Bool?
    var tokenTTL: Int?
    var vm: PartialVM?
    var image: String?
    /// Base VM image a prepare starts from (curated tart reference or a
    /// local VM name); nil = the default macOS base.
    var baseImage: String?
    var images: [PartialImage]?
    var vmBootTimeout: Int?
    var diskGB: Int?
    var tartPath: String?
    var tartSoftnet: Bool?
    var reserve: PartialReserve?
    var container: PartialContainer?
    var docker: PartialDocker?
    var runtimes: PartialRuntimes?
    var provisionScript: String?
    /// Removed key: decoded only so the loader can point at `projects:`.
    var toolchains: PartialToolchains?
    var toolchainCache: PartialCachePolicy?
    var maxProjectImages: Int?
    var projects: [PartialProject]?
    var accounts: [PartialAccount]?

    struct PartialAccount: Decodable {
        var name: String?
        var forge: String?
        var scope: String?
        var instance: String?
        var labels: [String]?
        var allowInsecureHTTP: Bool?
        var scaleSet: [String: String]?

        enum CodingKeys: String, CodingKey {
            case name, forge, scope, instance, labels
            case allowInsecureHTTP = "allow_insecure_http"
            case scaleSet = "scale_set"
        }
    }

    /// Gitea-family sections are gone (accounts: entries replace them);
    /// the shape is kept only for the removed-key rejection message.
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

    struct PartialProject: Decodable {
        var pattern: String?
        var repoFile: Bool?
        var toolchains: PartialToolchains?
        var shareCache: Bool?

        enum CodingKeys: String, CodingKey {
            case pattern
            case repoFile = "repo_file"
            case toolchains
            case shareCache = "share_cache"
        }
    }

    struct PartialImage: Decodable {
        var name: String?
        var baseImage: String?
        var labels: [String]?

        enum CodingKeys: String, CodingKey {
            case name, labels
            case baseImage = "base_image"
        }
    }

    struct PartialRoute: Decodable {
        var pattern: String?
        var runtime: String?
        var consent: Bool?
    }

    struct PartialReserve: Decodable {
        var cpu: Int?
        var memoryGB: Int?
        var diskGB: Int?

        enum CodingKeys: String, CodingKey {
            case cpu
            case memoryGB = "memory_gb"
            case diskGB = "disk_gb"
        }
    }

    /// Public because `ConfigLoader.parseToolchains` (the shared validation
    /// entry for project toolchains) exposes it.
    public struct PartialToolchains: Decodable {
        public var specs: [String]?
        public var brew: [String]?
        public var stacks: [String]?

        public init(specs: [String]? = nil, brew: [String]? = nil, stacks: [String]? = nil) {
            self.specs = specs
            self.brew = brew
            self.stacks = stacks
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
        case autoResume = "auto_resume"
        case tokenTTL = "token_ttl"
        case vm
        case image
        case images
        case baseImage = "base_image"
        case vmBootTimeout = "vm_boot_timeout"
        case diskGB = "disk_gb"
        case tartPath = "tart_path"
        case tartSoftnet = "tart_softnet"
        case reserve
        case gitea
        case forgejo
        case container
        case docker
        case runtimes
        case provisionScript = "provision_script"
        case toolchains
        case toolchainCache = "toolchain_cache"
        case maxProjectImages = "max_project_images"
        case projects
        case accounts
    }

    /// forgejo is a stored property (decoded for the removed-key rejection);
    /// the enum case above covers gitea's key.
}
