import Foundation

// FleetEngine — per-project toolchain images: resolving each queued job's
// toolchains, binding new VMs to the derived image their demand needs, and
// building the route a record provisions from.
extension FleetEngine {
    /// What `resolveProjectImages` learned about one forge's queue.
    struct ProjectImageDemand {
        /// Queued tart jobs per ready derived image name.
        var byImage: [String: Int] = [:]
        /// Notices for jobs still waiting on a bake, deduplicated.
        var notices: Set<String> = []
    }

    /// Resolves every queued tart job of `forge` to its toolchain set and the
    /// derived image that serves it. Jobs whose image is still baking (or
    /// failed) count as base-image demand, so they run on the base image
    /// meanwhile and never wait on a bake.
    func resolveProjectImages(for jobs: [ForgeJob], forge: Forge) async -> ProjectImageDemand {
        var result = ProjectImageDemand()
        let projects = projectsState.withLock { $0 }
        guard !projects.isEmpty else { return result }
        let model = routing
        for job in jobs where model.runtime(for: job) == .tart {
            let resolution = await projectSource.resolve(job: job, forge: forge, projects: projects)
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
