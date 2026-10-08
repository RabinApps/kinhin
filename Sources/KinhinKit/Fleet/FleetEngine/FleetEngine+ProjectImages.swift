import Foundation

// FleetEngine — per-project toolchain images: resolving each queued job's
// toolchains, binding new VMs to the derived image their demand needs, and
// building the route a record provisions from.
extension FleetEngine {
    /// What `resolveProjectImages` learned about one forge's queue.
    struct ProjectImageDemand {
        /// Queued tart jobs per image name: a named `images:` entry, or a ready derived project image.
        var byImage: [String: Int] = [:]
        /// Notices for jobs still waiting on a bake, deduplicated.
        var notices: Set<String> = []
    }

    /// Resolves every queued tart job of `forge` to its toolchain set and the
    /// derived image that serves it. Jobs whose image is still baking (or
    /// failed) count as base-image demand, so they run on the base image
    /// meanwhile and never wait on a bake.
    func resolveProjectImages(
        for jobs: [ForgeJob], forge: Forge, routerState: Router.Snapshot
    ) async -> ProjectImageDemand {
        var result = ProjectImageDemand()
        let projects = routerState.projects
        let images = routerState.images
        guard !projects.isEmpty || !images.isEmpty else { return result }
        let model = routerState.model
        // Jobs on a named image are counted straight away; the rest need their
        // repository's toolchains resolved. Those lookups (repo file reads)
        // run concurrently, bounded, then the results are applied in job
        // order so the bake requests and notices stay deterministic.
        var candidates: [ForgeJob] = []
        for job in jobs where model.runtime(for: job) == .tart {
            // A job that requests a named image's labels runs on that image; per-project
            // toolchain images are derived from the main image only, so they do not apply.
            if let named = ImageRouting.image(for: job.labels, in: images) {
                result.byImage[named.name, default: 0] += 1
                continue
            }
            if !projects.isEmpty { candidates.append(job) }
        }
        let source = projectSource
        let resolutions = try? await boundedMap(candidates, limit: 4) { job in
            await source.resolve(job: job, forge: forge, projects: projects)
        }
        guard let resolutions else { return result }  // cancelled mid-lookup
        for (job, resolution) in zip(candidates, resolutions) {
            if let warning = resolution.warning { Log.warn("engine", warning) }
            guard let toolchains = resolution.toolchains else { continue }
            let availability = await projectImages.request(toolchains: toolchains, shareCache: resolution.shareCache)
            switch availability {
            case .ready(let name):
                result.byImage[name, default: 0] += 1
            case .building:
                let repo = job.repository ?? "a repository"
                result.notices.insert(
                    "baking image for \(repo) (\(ProjectImageBuilder.summary(of: toolchains))), using base meanwhile")
            case .failed(_, let reason):
                let repo = job.repository ?? "a repository"
                result.notices.insert("image for \(repo) failed to bake (\(reason)); using the base image")
            }
        }
        return result
    }

    /// Active tart instances per image name ("" = the base image).
    func activeByImage() -> [String: Int] {
        var counts: [String: Int] = [:]
        for record in store.all where record.phase.isActive {
            let runtime = RuntimeID(rawValue: record.runtime ?? "") ?? routing.defaultRuntime
            guard runtime == .tart else { continue }
            counts[record.image ?? "", default: 0] += 1
        }
        return counts
    }

    /// The image a new tart instance should be cloned from: the one with the
    /// most unmet demand (nil = the base image). Ties go to a derived image.
    func chooseImage(demand: Demand) -> String? {
        guard !demand.byImage.isEmpty else { return nil }
        let active = activeByImage()
        let derivedTotal = demand.byImage.values.reduce(0, +)
        let baseUnmet = ((demand.byPool[.tart] ?? 0) - derivedTotal) - (active[""] ?? 0)
        var best: (image: String?, unmet: Int) = (nil, baseUnmet)
        for (image, count) in demand.byImage.sorted(by: { $0.key < $1.key }) {
            let unmet = count - (active[image] ?? 0)
            if unmet > 0, unmet >= best.unmet { best = (image, unmet) }
        }
        return best.unmet > 0 ? best.image : nil
    }

    /// The route a record provisions and registers with: the fleet's base
    /// image, or the derived image it was bound to at spawn.
    func route(forRecord id: String) -> RepoRoute {
        guard let image = store.all.first(where: { $0.id == id })?.image else { return RepoRoute.from(config: config) }
        guard let record = projectStore.record(named: image) else {
            return RepoRoute.from(config: config, image: image)
        }
        return RepoRoute.from(
            config: config, image: image, toolchains: record.toolchains.config, cacheMount: record.shareCache,
            cacheScope: record.shareCache ? record.key : nil)
    }

    /// Daily sweep of derived images beyond `max_project_images` / the age
    /// limit. Images a live instance was cloned from are kept.
    func pruneProjectImages() async {
        let inUse = Set(store.all.compactMap(\.image))
        await projectImages.prune(
            maxImages: config.maxProjectImages ?? ProjectImageBuilder.defaultMaxImages,
            maxAgeDays: ToolchainCachePolicy(from: config.toolchainCache).maxAgeDays, inUse: inUse)
    }
}
