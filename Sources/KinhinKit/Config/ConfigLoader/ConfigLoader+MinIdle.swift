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
        if cfg.imageMinIdle + cfg.warmPool > cap {
            throw ConfigError.invalid(
                "image_min_idle (\(cfg.imageMinIdle)) plus warm_pool (\(cfg.warmPool)) must be <= max_runners (\(cap))")
        }
        for image in cfg.images where image.minIdle + image.warmPool > cap {
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
        let total =
            cfg.imageMinIdle + cfg.images.reduce(0) { $0 + $1.minIdle } + (cfg.container?.minIdle ?? 0)
            + (cfg.docker?.minIdle ?? 0)
        if total > cap {
            throw ConfigError.invalid(
                "min_idle across image_min_idle, images:, container: and docker: (\(total)) must be <= max_runners (\(cap))"
            )
        }
        // A Linux Tart image is not bound by Apple's macOS limit. A named image without base_image bakes on the
        // default macOS base.
        let defaultIsMacOS = !TartBaseImage.isLinux(cfg.baseImage)
        let macOS =
            (defaultIsMacOS ? cfg.imageMinIdle : 0)
            + cfg.images.filter { !TartBaseImage.isLinux($0.baseImage) }.reduce(0) { $0 + $1.minIdle }
        if macOS > macOSVMsPerMac {
            throw ConfigError.invalid(
                "min_idle on macOS Tart images (image_min_idle and images:) adds up to \(macOS), but a Mac runs at "
                    + "most \(macOSVMsPerMac) macOS VMs at once, so the fleet could never keep that many idle")
        }
    }
}
