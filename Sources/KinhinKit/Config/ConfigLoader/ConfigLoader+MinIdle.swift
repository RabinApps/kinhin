import Foundation

// MARK: - min_idle (idle registered runners per pool and per Tart image)

extension ConfigLoader {
    /// Apple's Virtualization framework runs at most this many macOS VMs on one Mac at a time.
    static let macOSVMsPerMac = 2

    /// The `min_idle` floors across sections, checked once every section is parsed: each per-key value is already
    /// known to be `>= 0` (and Docker's within `max_slots`). Idle runners take slots under `max_runners` like warm
    /// VMs, so every floor, each image's floor plus its warm pool, and all floors together must fit there; and the
    /// floors on macOS Tart images together must fit Apple's two-VM limit, or the fleet could never hold them.
    static func validateMinIdle(_ cfg: KinhinConfig) throws {
        let cap = cfg.maxRunners
        if exceeds([cfg.imageMinIdle, cfg.warmPool], cap) {
            throw ConfigError.invalid(
                "image_min_idle (\(cfg.imageMinIdle)) plus warm_pool (\(cfg.warmPool)) must be <= max_runners (\(cap))")
        }
        for image in cfg.images where exceeds([image.minIdle, image.warmPool], cap) {
            throw ConfigError.invalid(
                "images: \(image.name) min_idle (\(image.minIdle)) plus its warm_pool (\(image.warmPool)) "
                    + "must be <= max_runners (\(cap))")
        }
        if let container = cfg.container, container.minIdle > cap {
            throw ConfigError.invalid("container.min_idle (\(container.minIdle)) must be <= max_runners (\(cap))")
        }
        if let docker = cfg.docker, docker.minIdle > cap {
            throw ConfigError.invalid("docker.min_idle (\(docker.minIdle)) must be <= max_runners (\(cap))")
        }
        let floors =
            [cfg.imageMinIdle] + cfg.images.map(\.minIdle) + [cfg.container?.minIdle ?? 0, cfg.docker?.minIdle ?? 0]
        if exceeds(floors, cap) {
            throw ConfigError.invalid(
                "min_idle across image_min_idle, images:, container: and docker: (\(total(floors))) must be <= "
                    + "max_runners (\(cap))")
        }
        // A Linux Tart image is not bound by Apple's macOS limit. A named image without base_image bakes on the
        // default macOS base.
        let defaultIsMacOS = !TartBaseImage.isLinux(cfg.baseImage)
        let macOS =
            [defaultIsMacOS ? cfg.imageMinIdle : 0]
            + cfg.images.filter { !TartBaseImage.isLinux($0.baseImage) }.map(\.minIdle)
        if exceeds(macOS, macOSVMsPerMac) {
            throw ConfigError.invalid(
                "min_idle on macOS Tart images (image_min_idle and images:) adds up to \(total(macOS)), but a Mac runs at "
                    + "most \(macOSVMsPerMac) macOS VMs at once, so the fleet could never keep that many idle")
        }
    }

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
