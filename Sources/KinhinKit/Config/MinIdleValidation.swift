import Foundation

/// One `min_idle` rule a config breaks: which floor it concerns (stable, for pinning an inline error next to a
/// control) and the English message the loader would reject the file with.
public struct MinIdleIssue: Equatable, Sendable {
    /// The floor (or the total) the issue belongs to.
    public enum Field: Hashable, Sendable {
        /// Top-level `image_min_idle` (the default Tart image).
        case imageMinIdle
        /// `images[].min_idle` of the named image.
        case image(String)
        /// `container.min_idle` of a section without `container.pools:`.
        case containerMinIdle
        /// `container.pools.<name>.min_idle`.
        case pool(String)
        /// `docker.min_idle`.
        case dockerMinIdle
        /// All floors together against `max_runners`.
        case total
        /// The floors on macOS Tart images together against Apple's two-VM limit.
        case macOS
    }

    public var field: Field
    public var message: String

    public init(field: Field, message: String) {
        self.field = field
        self.message = message
    }
}

/// The `min_idle` rules (idle registered runners per pool and per Tart image), checked on a typed config. The one
/// implementation behind both `ConfigLoader.parse` (which throws the first issue) and the app's inline errors
/// (which show them all before saving), so the two can never disagree.
public enum MinIdleValidation {
    /// Apple's Virtualization framework runs at most this many macOS VMs on one Mac at a time.
    public static let macOSVMsPerMac = 2

    /// Every rule `config` breaks, in the order the loader reports them (it throws the first). Idle runners take
    /// slots under `max_runners` like warm VMs, so every floor, each Tart image's floor plus its warm pool, and all
    /// floors together must fit there; Docker's floor must fit `docker.max_slots`, a pool's its `max`; and the
    /// floors on macOS Tart images together must fit Apple's two-VM limit, or the fleet could never hold them.
    /// Negative values are not reported here: the loader rejects them per key as it parses.
    public static func issues(for config: KinhinConfig) -> [MinIdleIssue] {
        var issues: [MinIdleIssue] = []
        let cap = config.maxRunners
        // A switched-off runtime or pool keeps its settings without being held to the limits: its floors are never kept.
        let tart = config.tartEnabled
        if tart, exceeds([config.imageMinIdle, config.warmPool], cap) {
            let message =
                "image_min_idle (\(config.imageMinIdle)) plus warm_pool (\(config.warmPool)) "
                + "must be <= max_runners (\(cap))"
            issues.append(.init(field: .imageMinIdle, message: message))
        }
        for image in config.images where tart && exceeds([image.minIdle, image.warmPool], cap) {
            let message =
                "images: \(image.name) min_idle (\(image.minIdle)) plus its warm_pool (\(image.warmPool)) "
                + "must be <= max_runners (\(cap))"
            issues.append(.init(field: .image(image.name), message: message))
        }
        for pool in config.container?.effectivePools ?? [] {
            let key = poolKey(pool)
            let field: MinIdleIssue.Field = pool.isNamed ? .pool(pool.name) : .containerMinIdle
            if pool.enabled, pool.minIdle > cap {
                issues.append(
                    .init(field: field, message: "\(key).min_idle (\(pool.minIdle)) must be <= max_runners (\(cap))"))
            }
            // Checked as the loader parses the pool, enabled or not.
            if let message = poolMaxMessage(key: key, minIdle: pool.minIdle, max: pool.max) {
                issues.append(.init(field: field, message: message))
            }
        }
        if let docker = config.docker {
            if docker.enabled, docker.minIdle > cap {
                let message = "docker.min_idle (\(docker.minIdle)) must be <= max_runners (\(cap))"
                issues.append(.init(field: .dockerMinIdle, message: message))
            }
            if let message = dockerSlotsMessage(minIdle: docker.minIdle, maxSlots: docker.maxSlots) {
                issues.append(.init(field: .dockerMinIdle, message: message))
            }
        }
        // With `container.pools:`, the section's own min_idle is only the pools' default: each pool's floor counts.
        // A disabled pool holds no idle runners, so its floor does not count.
        let floors =
            (tart ? [config.imageMinIdle] + config.images.map(\.minIdle) : [])
            + (config.container?.enabledPools.map(\.minIdle) ?? [])
            + [config.docker.flatMap { $0.enabled ? $0.minIdle : nil } ?? 0]
        if exceeds(floors, cap) {
            let message =
                "min_idle across image_min_idle, images:, container: (every pool) and docker: (\(total(floors))) must "
                + "be <= max_runners (\(cap))"
            issues.append(.init(field: .total, message: message))
        }
        // A Linux Tart image is not bound by Apple's macOS limit. A named image without base_image bakes on the
        // default macOS base.
        let defaultIsMacOS = !TartBaseImage.isLinux(config.baseImage)
        let macOS =
            [defaultIsMacOS && tart ? config.imageMinIdle : 0]
            + config.images.filter { tart && !TartBaseImage.isLinux($0.baseImage) }.map(\.minIdle)
        if exceeds(macOS, macOSVMsPerMac) {
            let message =
                "min_idle on macOS Tart images (image_min_idle and images:) adds up to \(total(macOS)), but a Mac "
                + "runs at most \(macOSVMsPerMac) macOS VMs at once, so the fleet could never keep that many idle"
            issues.append(.init(field: .macOS, message: message))
        }
        return issues
    }

    // MARK: - Per-key messages (shared with the loader's section parsers)

    /// `container.pools.<name>` for a named pool, `container` for the section itself.
    static func poolKey(_ pool: KinhinConfig.ContainerConfig.Pool) -> String {
        pool.isNamed ? "container.pools.\(pool.name)" : "container"
    }

    /// The message for a pool floor above the pool's own `max`, nil when it fits or the pool has no `max`.
    static func poolMaxMessage(key: String, minIdle: Int, max: Int?) -> String? {
        guard let max, minIdle > max else { return nil }
        return "\(key).min_idle (\(minIdle)) must be <= \(key).max (\(max))"
    }

    /// The message for a Docker floor above `docker.max_slots`, nil when it fits.
    static func dockerSlotsMessage(minIdle: Int, maxSlots: Int) -> String? {
        guard minIdle > maxSlots else { return nil }
        return "docker.min_idle (\(minIdle)) must be <= docker.max_slots (\(maxSlots))"
    }

    // MARK: - Overflow-safe sums

    /// `values` (each `>= 0`) added up, or nil when the sum passes `Int.max`: a huge `min_idle` must fail validation
    /// with a message, not trap the loader (and a saturated `Int.max` would wrongly fit `max_runners: Int.max`).
    private static func sum(_ values: [Int]) -> Int? {
        values.reduce(Int?.some(0)) { total, value in
            guard let total else { return nil }
            let (result, overflow) = total.addingReportingOverflow(value)
            return overflow ? nil : result
        }
    }

    /// Whether `values` add up to more than `cap`. A sum past `Int.max` exceeds every cap.
    private static func exceeds(_ values: [Int], _ cap: Int) -> Bool { sum(values).map { $0 > cap } ?? true }

    /// `values`' sum for a message.
    private static func total(_ values: [Int]) -> String { sum(values).map(String.init) ?? "more than \(Int.max)" }
}
