import Foundation

/// One line of the read-only "Repos" overview: a `projects:` entry, or the
/// "other repos" row for everything no entry covers.
public struct ProjectToolchainsRow: Sendable, Equatable, Identifiable {
    public enum Source: Sendable, Equatable {
        /// The repo's own `.kinhin.yml` is honored (`repo_file: true`); the
        /// versions are read from the file at each job's branch or tag.
        case repoFile
        /// The project entry's own `toolchains:` fallback.
        case projectFallback
        /// No toolchains are baked: jobs use the plain base image.
        case none
    }

    public var id: String { isDefault ? "<default>" : pattern }
    /// The `projects:` pattern ("owner/name" or "owner/*"); empty for the default row.
    public let pattern: String
    public let isDefault: Bool
    public let source: Source
    /// The project entry's own `toolchains:`, used when no `.kinhin.yml` is
    /// honored or usable. Empty when none is configured (and always for the
    /// "other repos" row).
    public let specs: [String]
    public let brew: [String]
    public let stacks: [String]
    /// The derived image that set maps to, when kinhin has built it. The
    /// "other repos" row shows the base image instead (see `baseImage`).
    public let images: [ProjectImageRecord]
    /// The base image jobs run on; set on the "other repos" row only.
    public let baseImage: String?
    public let shareCache: Bool

    public var hasToolchains: Bool { !specs.isEmpty || !brew.isEmpty || !stacks.isEmpty }
}

/// Read-only view of how toolchains resolve per repo, for the app's
/// Toolchains tab. Never writes config.
public struct ProjectToolchainsOverview: Sendable, Equatable {
    public let rows: [ProjectToolchainsRow]
    /// Derived images that no project's own toolchains account for: they come from
    /// `.kinhin.yml` files, whose versions are only known at job time.
    public let repoFileImages: [ProjectImageRecord]

    public init(rows: [ProjectToolchainsRow], repoFileImages: [ProjectImageRecord]) {
        self.rows = rows
        self.repoFileImages = repoFileImages
    }

    /// One row per `projects:` entry in declaration order, then the default row.
    public static func build(config: KinhinConfig, images: [ProjectImageRecord]) -> ProjectToolchainsOverview {
        func imageName(_ toolchains: KinhinConfig.ToolchainsConfig) -> String {
            let key = ToolchainImageKey.make(toolchains: toolchains, base: config.image, platform: .macOS)
            return ToolchainImageKey.imageName(base: config.image, key: key)
        }
        var claimed: Set<String> = []
        var rows: [ProjectToolchainsRow] = config.projects.map { project in
            let fallback = project.toolchains
            let matching = fallback.map { fallbackSet in
                images.filter { $0.name == imageName(fallbackSet) }
            }
            for image in matching ?? [] { claimed.insert(image.name) }
            return ProjectToolchainsRow(
                pattern: project.pattern, isDefault: false,
                source: project.repoFile ? .repoFile : (fallback == nil ? .none : .projectFallback),
                specs: fallback?.specs ?? [], brew: fallback?.brew ?? [], stacks: fallback?.stacks ?? [],
                images: matching ?? [], baseImage: nil, shareCache: project.shareCache ?? false)
        }
        rows.append(
            ProjectToolchainsRow(
                pattern: "", isDefault: true, source: .none, specs: [], brew: [], stacks: [], images: [],
                baseImage: config.image, shareCache: false))
        return ProjectToolchainsOverview(
            rows: rows, repoFileImages: images.filter { !claimed.contains($0.name) })
    }
}
