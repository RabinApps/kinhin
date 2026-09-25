import Foundation

/// Decode target mirroring kinhinConfig but with all fields optional so we
/// can produce precise validation errors instead of opaque decode failures.
/// Public because the toolchains validation entry (`parseToolchains`) takes
/// a `PartialToolchains` — the CLI's flag overrides reuse the same rules.
public struct PartialConfig: Decodable {
    var repo: String?
    var labels: [String]?
    var min_runners: Int?
    var max_runners: Int?
    var runners_per_vm: Int?
    var poll_interval: Int?
    var token_ttl: Int?
    var vm: PartialVM?
    var image: String?
    var vm_boot_timeout: Int?
    var disk_gb: Int?
    var tart_path: String?
    var reserve: PartialReserve?
    var gitea: PartialGitea?
    var container: PartialContainer?
    var docker: PartialDocker?
    var runtimes: PartialRuntimes?
    var provision_script: String?
    var toolchains: PartialToolchains?

    struct PartialGitea: Decodable {
        var instance: String?
        var scope: String?
        var labels: [String]?
    }

    struct PartialVM: Decodable {
        var cpu: Int?
        var memory_gb: Int?
        var ephemeral: Bool?
    }

    struct PartialContainer: Decodable {
        var image: String?
        var cpus: Int?
        var memory_gb: Int?
        var labels: [String]?
    }

    struct PartialDocker: Decodable {
        var image: String?
        var cpus: Int?
        var memory_gb: Int?
        var max_slots: Int?
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
        var memory_gb: Int?
    }

    /// Public because `ConfigLoader.parseToolchains` (the shared validation
    /// entry the CLI uses for `--toolchain/--stack` overrides) exposes it.
    public struct PartialToolchains: Decodable {
        public var specs: [String]?
        public var brew: [String]?
        public var stacks: [String]?
        public var share_cache: Bool?
        public var cache: PartialCachePolicy?

        public init(
            specs: [String]? = nil, brew: [String]? = nil, stacks: [String]? = nil, share_cache: Bool? = nil,
            cache: PartialCachePolicy? = nil
        ) {
            self.specs = specs
            self.brew = brew
            self.stacks = stacks
            self.share_cache = share_cache
            self.cache = cache
        }
    }

    public struct PartialCachePolicy: Decodable {
        public var auto_prune: Bool?
        public var max_age_days: Int?
        public var max_gb: Int?

        public init(auto_prune: Bool? = nil, max_age_days: Int? = nil, max_gb: Int? = nil) {
            self.auto_prune = auto_prune
            self.max_age_days = max_age_days
            self.max_gb = max_gb
        }
    }
}
