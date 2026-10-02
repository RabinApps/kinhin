import Foundation

/// Eager per-project bake and inspection, shared by the CLI
/// (`image prepare --project`, `toolchains --project`): resolve a repo's
/// toolchains the same way the engine does for a queued job, then bake or
/// describe the derived image.
public struct ProjectImageService: Sendable {
    public struct Result: Sendable, Equatable {
        public let repository: String
        public let source: String
        public let summary: String
        public let imageName: String?
        public let warning: String?
        public let baked: Bool

        public var summaryLine: String {
            guard let imageName else {
                return "\(repository): no toolchains to bake (\(source)); jobs use the base image"
            }
            return baked
                ? "project image ready: \(imageName) (\(summary); \(source))"
                : "\(repository) resolves to \(imageName) (\(summary); \(source))"
        }
    }

    let config: KinhinConfig
    let tart: TartControlling
    let store: ProjectImageStore
    /// Test seam: the forge that serves the repo (nil = build one from the
    /// matching account's stored token).
    let forge: Forge?
    let bake: ProjectImageBuilder.Bake?

    public init(
        config: KinhinConfig, tart: TartControlling, store: ProjectImageStore = ProjectImageStore()
    ) {
        self.init(config: config, tart: tart, store: store, forge: nil, bake: nil)
    }

    init(
        config: KinhinConfig, tart: TartControlling, store: ProjectImageStore, forge: Forge?,
        bake: ProjectImageBuilder.Bake?
    ) {
        self.config = config
        self.tart = tart
        self.store = store
        self.forge = forge
        self.bake = bake
    }

    /// Derived images that `prune` would delete: beyond `max_project_images`
    /// (default 8, least recently used first) or unused for the cache's
    /// `max_age_days`. Images a live runner VM was cloned from are kept.
    public static func pruneCandidates(
        config: KinhinConfig?, store: ProjectImageStore = ProjectImageStore(), inUse: Set<String>
    ) -> [String] {
        store.pruneCandidates(
            maxImages: config?.maxProjectImages ?? ProjectImageBuilder.defaultMaxImages,
            maxAgeDays: ToolchainCachePolicy(from: config?.toolchainCache).maxAgeDays, protected: inUse)
    }

    /// Deletes the derived images `pruneCandidates` names; returns them.
    @discardableResult
    public static func prune(
        config: KinhinConfig, tart: TartControlling, store: ProjectImageStore = ProjectImageStore(),
        inUse: Set<String>
    ) async -> [String] {
        await ProjectImageBuilder(tart: tart, store: store, baseImage: config.image).prune(
            maxImages: config.maxProjectImages ?? ProjectImageBuilder.defaultMaxImages,
            maxAgeDays: ToolchainCachePolicy(from: config.toolchainCache).maxAgeDays, inUse: inUse)
    }

    /// Deletes every derived image: they were cloned from a base image that
    /// has just been rebuilt, so they are stale (running instances are
    /// independent clones and are unaffected).
    public static func invalidateAll(tart: TartControlling, store: ProjectImageStore = ProjectImageStore()) async {
        for record in store.all {
            await bestEffortAsync("images", "deleting stale project image \(record.name)") {
                try await tart.delete(name: record.name)
            }
            store.remove(name: record.name)
        }
    }

    /// Deletes the derived images cloned from `base` only (it was just rebuilt);
    /// images derived from other bases are still valid.
    public static func invalidate(
        base: String, tart: TartControlling, store: ProjectImageStore = ProjectImageStore()
    ) async {
        for record in store.all where record.base == base {
            await bestEffortAsync("images", "deleting stale project image \(record.name)") {
                try await tart.delete(name: record.name)
            }
            store.remove(name: record.name)
        }
    }

    /// What `repository` (at `ref`) resolves to, without baking.
    public func describe(repository: String, ref: String?) async throws -> Result {
        let (resolution, builder) = try await resolve(repository: repository, ref: ref)
        return await result(for: resolution, repository: repository, builder: builder, baked: false)
    }

    /// Resolves and bakes the derived image now, waiting for it to finish.
    public func prepare(repository: String, ref: String?) async throws -> Result {
        let (resolution, builder) = try await resolve(repository: repository, ref: ref)
        guard let toolchains = resolution.toolchains else {
            return await result(for: resolution, repository: repository, builder: builder, baked: false)
        }
        var availability = await builder.request(toolchains: toolchains, shareCache: resolution.shareCache)
        await builder.waitForBakes()
        availability = await builder.request(toolchains: toolchains, shareCache: resolution.shareCache)
        switch availability {
        case .ready:
            return await result(for: resolution, repository: repository, builder: builder, baked: true)
        case .failed(_, let reason):
            throw ImageError.provisioningFailed(reason)
        case .building:
            throw ImageError.provisioningFailed("the bake did not finish")
        }
    }

    private func resolve(repository: String, ref: String?) async throws -> (ProjectResolution, ProjectImageBuilder) {
        guard repository.split(separator: "/").count == 2 else {
            throw ConfigError.invalid("--project must be owner/name, got '\(repository)'")
        }
        guard let project = ProjectToolchainResolver.project(for: repository, in: config.projects) else {
            throw ConfigError.invalid(
                "no projects: entry matches '\(repository)' — add one (projects: [{pattern: \(repository), repo_file: true}])"
            )
        }
        var file: Data?
        if project.repoFile {
            let forge = try self.forge ?? serving(repository)
            file = try await forge.projectFile(repository: repository, ref: ref)
        }
        let resolution = ProjectToolchainResolver.resolve(
            repository: repository, projects: config.projects, repoFile: file)
        if let warning = resolution.warning { Log.warn("images", warning) }
        let builder = ProjectImageBuilder(tart: tart, store: store, baseImage: config.image, bake: bake)
        return (resolution, builder)
    }

    private func result(
        for resolution: ProjectResolution, repository: String, builder: ProjectImageBuilder, baked: Bool
    ) async -> Result {
        let source: String
        switch resolution.source {
        case .repoFile: source = "from .kinhin.yml"
        case .project(let pattern): source = "from projects: \(pattern)"
        case .global: source = "no toolchains declared"
        }
        guard let toolchains = resolution.toolchains else {
            return Result(
                repository: repository, source: source, summary: "", imageName: nil, warning: resolution.warning,
                baked: false)
        }
        return Result(
            repository: repository, source: source, summary: ProjectImageBuilder.summary(of: toolchains),
            imageName: await builder.imageName(for: toolchains, shareCache: resolution.shareCache),
            warning: resolution.warning, baked: baked)
    }

    /// A GitHub forge for the account whose scope covers the repository.
    private func serving(_ repository: String) throws -> Forge {
        let owner = repository.split(separator: "/").first.map(String.init) ?? ""
        guard
            let account = config.accounts.first(where: {
                $0.forge == .github
                    && ($0.scope.caseInsensitiveCompare(repository) == .orderedSame
                        || $0.scope.caseInsensitiveCompare(owner) == .orderedSame)
            })
        else {
            throw ConfigError.invalid(
                "no GitHub account covers '\(repository)': reading .kinhin.yml needs an accounts: entry for it")
        }
        guard let token = try KeychainTokenStore.load(forge: account.forge, name: account.name) else {
            throw ConfigError.invalid("no token stored for account '\(account.name)' (kinhin auth set)")
        }
        return GitHubForge(
            credentials: .github(token: token, scope: account.scope), labels: config.labels,
            client: GitHubClient(credentials: GitHubCredentials(token: token, scope: account.scope)),
            account: account.name)
    }
}
