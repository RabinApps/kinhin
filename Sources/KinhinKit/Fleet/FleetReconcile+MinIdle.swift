import Foundation

// FleetEngine — `min_idle`: the floors the scale plan keeps, and the engine-side check on its top-ups.
extension FleetEngine {
    /// Idle registered instances to keep per pool and per Tart image: the default image's `image_min_idle`
    /// (keyed "", like its warm pool), each `images:` entry's `min_idle`, and `container.min_idle` /
    /// `docker.min_idle`. `images` is the router snapshot's table, so a reload applies on the next pass; its
    /// synthesized default-image entry carries 0, so the base image is only ever keyed "". Named images in
    /// `unprepared` keep no floor this pass (see `unpreparedIdleImages`).
    func minIdleTargets(images: [KinhinConfig.ImageConfig], unprepared: Set<String> = []) -> [ScalePlan.IdleKey: Int] {
        var targets: [ScalePlan.IdleKey: Int] = [:]
        if config.imageMinIdle > 0 { targets[.init(runtime: .tart)] = config.imageMinIdle }
        for image in images where image.minIdle > 0 && !unprepared.contains(image.name) {
            targets[.init(runtime: .tart, image: image.name)] = image.minIdle
        }
        if let container = config.container, container.minIdle > 0 {
            targets[.init(runtime: .appleContainer)] = container.minIdle
        }
        if let docker = config.docker, docker.minIdle > 0 { targets[.init(runtime: .docker)] = docker.minIdle }
        return targets
    }

    /// The named images with a `min_idle` floor that are not prepared. The plan leaves their floors out before it
    /// sizes anything, so a top-up that could only fail never takes room, evicts a warm VM or holds back the warm
    /// pool; a clone of one would fail, and repeated failures would hold the whole Tart runtime in spawn backoff.
    /// Each skipped image is logged once until it is prepared (the warm pool skips such images the same way).
    func unpreparedIdleImages(images: [KinhinConfig.ImageConfig]) async -> Set<String> {
        let named = Set(images.filter { $0.minIdle > 0 }.map(\.name))
        guard !named.isEmpty else { return [] }
        let missing = named.subtracting(Set(await listedTartVMs().map(\.name)))
        let newlySkipped = tartListing.withLock { state -> [String] in
            state.idleSkipped.formIntersection(missing)
            let fresh = missing.subtracting(state.idleSkipped)
            state.idleSkipped.formUnion(missing)
            return fresh.sorted()
        }
        for image in newlySkipped {
            Log.warn("engine", "min_idle for image \(image) skipped: it is not prepared")
        }
        return missing
    }

    /// The plan's slots minus any `min_idle` top-up that would still clone a named image that is not prepared: a
    /// safety net behind `unpreparedIdleImages` (a reload between the two can change the image table). Admitted
    /// top-ups are logged, so the reason an instance started without a queued job is on record.
    func admitIdleTopUps(_ slots: [ScalePlan.Slot]) async -> [ScalePlan.Slot] {
        let idle = slots.filter(\.idle)
        guard !idle.isEmpty else { return slots }
        let named = Set(idle.filter { $0.runtime == .tart && $0.claim == nil }.compactMap(\.image))
        var missing: Set<String> = []
        if !named.isEmpty {
            missing = named.subtracting(Set(await listedTartVMs().map(\.name)))
            for image in missing.sorted() {
                Log.warn("engine", "min_idle for image \(image) skipped: it is not prepared")
            }
        }
        let admitted = slots.filter { slot in
            !(slot.idle && slot.claim == nil && slot.image.map { missing.contains($0) } == true)
        }
        let started = admitted.filter(\.idle).map { slot in
            ScalePlan.IdleKey(runtime: slot.runtime, image: slot.image ?? "").description
        }
        if !started.isEmpty {
            Log.info("engine", "keeping idle runners (min_idle): starting \(started.joined(separator: ", "))")
        }
        return admitted
    }
}
