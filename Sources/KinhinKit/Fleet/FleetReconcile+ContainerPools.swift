import Foundation

// FleetEngine — named container pools whose image is not built: found from a cached image listing and left out of the
// scale plan, as `unpreparedIdleImages` does for unprepared Tart images' floors.
extension FleetEngine {
    /// What the engine last learned from `container image list` (see `FleetEngine.containerImageListing`).
    struct ContainerImageListing: Sendable {
        var names: [String] = []
        var fetchedAt: Date?
        /// Named pools left out for an unbuilt image, so each skip is logged once until the image exists.
        var skipped: Set<String> = []
    }

    /// How long one image listing serves the reconcile passes that ask for it. A pool whose image was just baked
    /// (`kinhin image prepare --container --pool NAME`, another process) starts at most this long later.
    static let containerImageListingMaxAge: TimeInterval = 60

    /// The local Apple container images, reused for `containerImageListingMaxAge`; nil when the CLI could not list
    /// them (not cached, so the next pass asks again).
    func listedContainerImages() async -> [String]? {
        let fresh = containerImageListing.withLock { state -> [String]? in
            guard let at = state.fetchedAt, Date().timeIntervalSince(at) < Self.containerImageListingMaxAge else {
                return nil
            }
            return state.names
        }
        if let fresh { return fresh }
        guard let runtime = runtimesByRuntime[.appleContainer] as? AppleContainerRuntime else { return nil }
        let names: [String]
        do {
            names = try await runtime.listedImageNames()
        } catch {
            // A cancelled pass discards it; anything else is logged, not hidden.
            if !(error is CancellationError) {
                Log.warn("reconcile", "container image list failed: \(error.localizedDescription)")
            }
            return nil
        }
        containerImageListing.withLock { state in
            state.names = names
            state.fetchedAt = Date()
        }
        return names
    }

    /// The named container pools whose image is not built. The plan leaves them out before it sizes anything
    /// (`ScalePlan.Input.exclude`): a runner of one could only fail to start, its failures would hold every pool in
    /// the Apple container spawn backoff, and its `min_idle` would retry forever. Each skipped pool is logged once
    /// until its image exists. A listing that failed skips nothing (the pools would then all look unbuilt), and a
    /// section without `pools:` never lists at all.
    func unpreparedContainerPools() async -> Set<String> {
        guard let pools = config.container?.pools, !pools.isEmpty, let listed = await listedContainerImages() else {
            return []
        }
        let missing = Set(config.container?.poolsMissingImage(listed: listed).map(\.name) ?? [])
        let newlySkipped = containerImageListing.withLock { state -> [String] in
            state.skipped.formIntersection(missing)
            let fresh = missing.subtracting(state.skipped)
            state.skipped.formUnion(missing)
            return fresh.sorted()
        }
        for name in newlySkipped {
            let image = pools.first { $0.name == name }?.image ?? ""
            Log.warn(
                "engine",
                "container pool \(name) skipped: its image \(image) is not built (kinhin image prepare --container "
                    + "--pool \(name)); its jobs wait")
        }
        return missing
    }
}
