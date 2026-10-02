import Foundation

/// Which toolchain set a job's runner should boot with, and why.
struct ProjectResolution: Sendable, Equatable {
    enum Source: Sendable, Equatable {
        /// The repo's own `.kinhin.yml`, read at the job's ref.
        case repoFile
        /// The matching `projects:` entry's fallback `toolchains:`.
        case project(pattern: String)
        /// The global `toolchains:` section (or none).
        case global
    }

    /// nil = the global image (no derived image is needed).
    let toolchains: KinhinConfig.ToolchainsConfig?
    let source: Source
    let shareCache: Bool
    /// Set when a repo file was present but unusable; the job falls back.
    let warning: String?

    static let global = ProjectResolution(toolchains: nil, source: .global, shareCache: false, warning: nil)

    /// True when this job needs a derived image rather than the global one.
    var needsDerivedImage: Bool { toolchains != nil }
}

/// Pure resolution of a queued job's toolchains: `.kinhin.yml` at the ref
/// (when the matching project opts in) → the project's fallback → global.
enum ProjectToolchainResolver {
    /// The `projects:` entry covering `repository`: exact patterns win over
    /// `owner/*`, then the first declared.
    static func project(for repository: String, in projects: [KinhinConfig.ProjectConfig])
        -> KinhinConfig.ProjectConfig?
    {
        let matches = projects.filter { $0.matches(repository) }
        return matches.first { !$0.pattern.hasSuffix("/*") } ?? matches.first
    }

    /// - Parameters:
    ///   - repoFile: the fetched `.kinhin.yml` bytes (nil = absent or not
    ///     fetched). Ignored unless the project has `repo_file`. For a fork's
    ///     PR the caller passes the base repo's default-branch file, never
    ///     the fork's own.
    ///   - isFork: fork PRs never mount the host cache.
    static func resolve(
        repository: String?, projects: [KinhinConfig.ProjectConfig], repoFile: Data?, isFork: Bool = false
    ) -> ProjectResolution {
        guard let repository, let project = project(for: repository, in: projects) else { return .global }
        let shareCache = project.shareCache == true && !isFork
        var warning: String?
        if project.repoFile, let repoFile {
            do {
                if let toolchains = try ProjectFileLoader.parse(repoFile) {
                    return ProjectResolution(
                        toolchains: toolchains, source: .repoFile, shareCache: shareCache, warning: nil)
                }
            } catch {
                warning =
                    "\(repository): \((error as? LocalizedError)?.errorDescription ?? "\(error)") — repo file ignored"
            }
        }
        if let fallback = project.toolchains {
            return ProjectResolution(
                toolchains: fallback, source: .project(pattern: project.pattern), shareCache: shareCache,
                warning: warning)
        }
        return ProjectResolution(toolchains: nil, source: .global, shareCache: shareCache, warning: warning)
    }
}
