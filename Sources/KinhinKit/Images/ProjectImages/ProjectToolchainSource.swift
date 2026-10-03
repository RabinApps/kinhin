import Foundation

/// Resolves a queued job's toolchains: fetches the repo's `.kinhin.yml` from
/// the forge when the matching project opts in, then applies
/// `ProjectToolchainResolver`. File reads are cached per (repository, sha),
/// so a queue of jobs for one commit costs a single API call; reads without
/// a sha expire quickly.
actor ProjectToolchainSource {
    private struct Entry {
        let data: Data?
        let at: Date
        let permanent: Bool
    }

    /// How long a sha-less (branch-only) read is reused.
    static let branchTTL: TimeInterval = 120
    private static let maxEntries = 256

    private var cache: [String: Entry] = [:]
    /// Reads under way, so concurrent lookups of the same file share one call.
    private var inFlight: [String: Task<Data?, Error>] = [:]
    private let now: @Sendable () -> Date

    init(now: @escaping @Sendable () -> Date = { Date() }) {
        self.now = now
    }

    func resolve(job: ForgeJob, forge: Forge, projects: [KinhinConfig.ProjectConfig]) async -> ProjectResolution {
        guard let repository = job.repository,
            let project = ProjectToolchainResolver.project(for: repository, in: projects)
        else { return .global }
        var fetchWarning: String?
        var file: Data?
        if project.repoFile {
            do {
                file = try await projectFile(repository: repository, job: job, forge: forge)
            } catch {
                let reason = (error as? LocalizedError)?.errorDescription ?? "\(error)"
                fetchWarning = "\(repository): could not read \(ProjectFileLoader.fileName): \(reason)"
            }
        }
        let resolution = ProjectToolchainResolver.resolve(
            repository: repository, projects: projects, repoFile: file, isFork: job.isFork)
        guard let fetchWarning else { return resolution }
        return ProjectResolution(
            toolchains: resolution.toolchains, source: resolution.source, shareCache: resolution.shareCache,
            warning: resolution.warning ?? fetchWarning)
    }

    /// A fork's PR reads the base repository's default branch, never the
    /// fork's own file.
    private func projectFile(repository: String, job: ForgeJob, forge: Forge) async throws -> Data? {
        let ref = job.isFork ? nil : job.ref
        let sha = job.isFork ? nil : job.sha
        let key = "\(forge.account)|\(repository)|\(sha ?? "ref:\(ref ?? "default")")"
        let stamp = now()
        if let hit = cache[key], hit.permanent || stamp.timeIntervalSince(hit.at) < Self.branchTTL {
            return hit.data
        }
        if let running = inFlight[key] { return try await running.value }
        let task = Task { try await forge.projectFile(repository: repository, ref: sha ?? ref) }
        inFlight[key] = task
        defer { inFlight[key] = nil }
        let data = try await task.value
        if cache.count >= Self.maxEntries { cache.removeAll(keepingCapacity: true) }
        cache[key] = Entry(data: data, at: stamp, permanent: sha != nil)
        return data
    }
}
