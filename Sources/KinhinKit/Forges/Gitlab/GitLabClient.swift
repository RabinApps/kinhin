import Foundation
import Synchronization

#if canImport(FoundationNetworking)
    import FoundationNetworking
#endif

/// GitLab REST (v4) client covering what the fleet needs: scope resolution,
/// per-runner creation (`POST /user/runners`, GitLab ≥ 16), runner listing
/// and deletion, and demand from the scope's projects' pending/running jobs.
///
/// GitLab has no group-wide job queue, so a group scope reads each recently
/// active project's jobs (bounded concurrency, capped per poll). The group's
/// project list is cached for a few minutes.
public struct GitLabClient: Sendable {
    let credentials: GitLabCredentials
    /// The shared send/retry pipeline (headers, status mapping, backoff).
    let transport: ForgeTransport
    /// Projects polled per read of a group's jobs.
    let maxProjectsPerPoll = 50
    static let jobsPerPage = 100
    /// Bounds one project's walk: 500 jobs in a single state is far past any fleet's demand.
    static let maxJobPages = 5
    /// Concurrent per-project job reads.
    let maxConcurrentReads = 8
    /// How long a group's project list is reused.
    let projectListTTL: TimeInterval = 300
    /// Projects without activity for this long are not polled for jobs.
    let activityWindow: TimeInterval = 24 * 3600
    /// stdlib `Mutex` is non-Copyable, so a struct cannot store one directly;
    /// the cache lives in a shared class box instead.
    private let projectCache = ProjectListCache()
    /// The budget the last response reported (`RateLimit-*` headers); shared
    /// across copies of the client.
    private let rateLimits = RateLimitBox()

    /// Reference cell for the group project list plus its fetch time.
    private final class ProjectListCache: Sendable {
        let mutex = Mutex<(fetched: Date, projects: [GitLabProjectRef])?>(nil)
    }

    /// The API budget the last response reported; nil when the instance sends
    /// no rate-limit headers (self-managed instances often do not).
    var rateLimit: ForgeRateLimit? { rateLimits.current }

    public init(credentials: GitLabCredentials, session: URLSession? = nil) {
        self.credentials = credentials
        self.transport = ForgeTransport(
            session: ForgeHTTP.session(session), forge: .gitlab, authorization: .privateToken(credentials.token))
    }

    // MARK: - Scope

    /// Resolves the configured path to a project or, failing that, a group.
    /// Doubles as the permission probe: it fails fast on a bad token or path.
    public func resolveScope() async throws -> GitLabScope {
        let encoded = Self.encodePathSegment(credentials.scope)
        do {
            let (data, _) = try await send("GET", "/projects/\(encoded)")
            let project: GitLabProjectRef = try decode(data, "project")
            return .project(id: project.id, path: project.path)
        } catch ForgeAPIError.notFound {
            // Not a project (or not visible as one): try the group below.
        }
        do {
            let (data, _) = try await send("GET", "/groups/\(encoded)")
            struct Group: Decodable { let id: Int; let full_path: String }
            let group: Group = try decode(data, "group")
            return .group(id: group.id, path: group.full_path)
        } catch ForgeAPIError.notFound {
            throw ForgeAPIError.notFound(forge: .gitlab, what: "project or group '\(credentials.scope)'")
        }
    }

    /// Projects and groups the token can serve, for the scope pickers:
    /// projects where it is at least Maintainer, groups where it is Owner.
    public func listRepositories() async throws -> [RepoRef] {
        let projects: [GitLabProjectRef] = try await paged(
            "/projects",
            [
                URLQueryItem(name: "membership", value: "true"),
                URLQueryItem(name: "min_access_level", value: "40"),
                URLQueryItem(name: "simple", value: "true"),
                URLQueryItem(name: "order_by", value: "last_activity_at"),
            ], what: "projects")
        struct Group: Decodable { let full_path: String }
        let groups: [Group] = try await paged(
            "/groups", [URLQueryItem(name: "min_access_level", value: "50")], what: "groups")
        let refs = projects.map { RepoRef(fullName: $0.path) } + groups.map { RepoRef(fullName: $0.full_path) }
        return refs.sorted { $0.fullName.localizedCaseInsensitiveCompare($1.fullName) == .orderedAscending }
    }

    // MARK: - Runners

    /// Creates one runner in the scope and returns its authentication token.
    /// `run_untagged` is off: the runner only takes jobs whose tags it has.
    func createRunner(in scope: GitLabScope, name: String, tags: [String]) async throws -> GitLabCreatedRunner {
        var body: [String: Any] = [
            "description": name,
            "tag_list": tags,
            "run_untagged": false,
        ]
        switch scope {
        case .project(let id, _):
            body["runner_type"] = "project_type"
            body["project_id"] = id
        case .group(let id, _):
            body["runner_type"] = "group_type"
            body["group_id"] = id
        }
        let json = try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])
        let (data, _) = try await send("POST", "/user/runners", body: json)
        return try decode(data, "created runner")
    }

    /// The scope's own runners (not inherited shared or group runners).
    public func listRunners(in scope: GitLabScope) async throws -> [GitLabRunner] {
        switch scope {
        case .project(let id, _):
            return try await paged(
                "/projects/\(id)/runners", [URLQueryItem(name: "type", value: "project_type")], what: "runners")
        case .group(let id, _):
            return try await paged(
                "/groups/\(id)/runners", [URLQueryItem(name: "type", value: "group_type")], what: "runners")
        }
    }

    func deleteRunner(id: Int) async throws {
        _ = try await send("DELETE", "/runners/\(id)")
    }

    // MARK: - Jobs

    enum JobStatus: String { case pending, running }

    /// One project's contribution to a job read.
    private enum ProjectRead: Sendable {
        case jobs([GitLabJob])
        case failed(project: String, error: any Error)
    }

    /// The scope's jobs with the given status, attributed to their project.
    ///
    /// A single-project scope has nothing to fall back to: every failure
    /// (403, 404, 5xx) reaches the caller, so a revoked or mistyped scope is
    /// an error, not an empty queue. A group fans out over its projects: one
    /// project the token cannot read, or that errors, is skipped with a
    /// warning so it cannot hide the others' demand. When every project fails
    /// the first error is rethrown (an outage is not "no jobs"), and a 401
    /// always is (the token is wrong for all of them).
    func jobs(_ status: JobStatus, in scope: GitLabScope) async throws -> [GitLabJob] {
        let projects = try await projects(in: scope)
        let skipsFailures = scope.isGroup
        let reads = try await withThrowingTaskGroup(of: ProjectRead.self) { group in
            var remaining = projects.prefix(maxProjectsPerPoll).makeIterator()
            func addNext() -> Bool {
                guard let project = remaining.next() else { return false }
                group.addTask {
                    do {
                        return .jobs(try await jobs(status, project: project))
                    } catch let error as ForgeAPIError where skipsFailures && error != .unauthorized(forge: .gitlab) {
                        return .failed(project: project.path, error: error)
                    }
                }
                return true
            }
            for _ in 0..<maxConcurrentReads {
                guard addNext() else { break }
            }
            var reads: [ProjectRead] = []
            while let read = try await group.next() {
                reads.append(read)
                _ = addNext()
            }
            return reads
        }
        var all: [GitLabJob] = []
        var failures: [(project: String, error: any Error)] = []
        for read in reads {
            switch read {
            case .jobs(let jobs): all.append(contentsOf: jobs)
            case .failed(let project, let error): failures.append((project, error))
            }
        }
        for failure in failures {
            Log.warn("gitlab", "skipping jobs of \(failure.project): \(failure.error.localizedDescription)")
        }
        if let first = failures.first, failures.count == reads.count { throw first.error }
        return all.sorted { $0.id < $1.id }
    }

    private func jobs(_ status: JobStatus, project: GitLabProjectRef) async throws -> [GitLabJob] {
        struct Job: Decodable {
            let id: Int
            let name: String
            let tag_list: [String]?
            let runner: Runner?
            let ref: String?
            let commit: Commit?
            let pipeline: Pipeline?
            let created_at: String?
            let started_at: String?
            struct Pipeline: Decodable {
                let id: Int?
                let source: String?
                let ref: String?
            }
            struct Runner: Decodable { let description: String? }
            struct Commit: Decodable { let id: String? }
        }
        // A project with more than a page of jobs in one state (a busy shared project) keeps the rest on later pages.
        var jobs: [Job] = []
        var seen = Set<Int>()
        for page in 1...Self.maxJobPages {
            let (data, _) = try await send(
                "GET", "/projects/\(project.id)/jobs",
                [
                    URLQueryItem(name: "scope[]", value: status.rawValue),
                    URLQueryItem(name: "per_page", value: "\(Self.jobsPerPage)"),
                    URLQueryItem(name: "page", value: "\(page)"),
                ])
            let batch: [Job] = try decode(data, "jobs")
            // Pages shift while jobs change state: a job can show up on two of them.
            jobs.append(contentsOf: batch.filter { seen.insert($0.id).inserted })
            if batch.count < Self.jobsPerPage { break }
        }
        return jobs.map {
            GitLabJob(
                id: $0.id, name: $0.name, tags: $0.tag_list ?? [], project: project.path,
                runnerDescription: $0.runner?.description, ref: $0.ref, sha: $0.commit?.id, projectID: project.id,
                pipelineID: $0.pipeline?.id,
                fromMergeRequest: $0.pipeline?.source == "merge_request_event"
                    || ($0.ref ?? $0.pipeline?.ref ?? "").hasPrefix("refs/merge-requests/"),
                createdAt: PipelineParsing.date($0.created_at), startedAt: PipelineParsing.date($0.started_at))
        }
    }

    /// A pipeline's jobs (stage order) and its page, for the app's live
    /// pipeline view. GitLab's API has no step list below the job.
    func pipeline(projectID: Int, pipelineID: Int) async throws -> (info: GitLabPipelineInfo, jobs: [GitLabPipelineJob])
    {
        let (infoData, _) = try await send("GET", "/projects/\(projectID)/pipelines/\(pipelineID)")
        let info: GitLabPipelineInfo = try decode(infoData, "pipeline")
        let (jobsData, _) = try await send(
            "GET", "/projects/\(projectID)/pipelines/\(pipelineID)/jobs",
            [URLQueryItem(name: "per_page", value: "100")])
        let jobs: [GitLabPipelineJob] = try decode(jobsData, "pipeline jobs")
        return (info, jobs.sorted { $0.id < $1.id })
    }

    /// One job's state and times (`project` is the `path_with_namespace`). A single read, for telemetry.
    func jobDetail(project: String, jobID: Int) async throws -> GitLabJobDetail {
        let (data, _) = try await send("GET", "/projects/\(Self.encodePathSegment(project))/jobs/\(jobID)")
        return try decode(data, "job")
    }

    /// A job's trace (its log so far; live while the job runs).
    func jobTrace(projectID: Int, jobID: Int) async throws -> String {
        let (data, _) = try await send("GET", "/projects/\(projectID)/jobs/\(jobID)/trace", accept: "text/plain")
        return String(decoding: data, as: UTF8.self)
    }

    /// The projects whose jobs a scope's demand comes from. Groups list
    /// recently active projects (subgroups included), cached briefly.
    func projects(in scope: GitLabScope) async throws -> [GitLabProjectRef] {
        switch scope {
        case .project(let id, let path):
            return [GitLabProjectRef(id: id, path: path)]
        case .group(let id, _):
            let cached = projectCache.mutex.withLock { $0 }
            if let cached, Date().timeIntervalSince(cached.fetched) < projectListTTL {
                return cached.projects
            }
            let since = ISO8601DateFormatter().string(from: Date().addingTimeInterval(-activityWindow))
            let projects: [GitLabProjectRef] = try await paged(
                "/groups/\(id)/projects",
                [
                    URLQueryItem(name: "include_subgroups", value: "true"),
                    URLQueryItem(name: "archived", value: "false"),
                    // Projects shared INTO the group are not the group's to serve.
                    URLQueryItem(name: "with_shared", value: "false"),
                    URLQueryItem(name: "simple", value: "true"),
                    URLQueryItem(name: "order_by", value: "last_activity_at"),
                    URLQueryItem(name: "last_activity_after", value: since),
                ], what: "group projects")
            projectCache.mutex.withLock { $0 = (Date(), projects) }
            return projects
        }
    }

    // MARK: - Token and instance

    /// The scopes of the token in use (`GET /personal_access_tokens/self`;
    /// group and project access tokens answer too).
    func tokenScopes() async throws -> [String] {
        let (data, _) = try await send("GET", "/personal_access_tokens/self")
        struct Info: Decodable { let scopes: [String] }
        let info: Info = try decode(data, "token info")
        return info.scopes
    }

    /// The instance version string, e.g. "17.4.1-ee".
    func version() async throws -> String {
        let (data, _) = try await send("GET", "/version")
        struct Version: Decodable { let version: String }
        let version: Version = try decode(data, "version")
        return version.version
    }

    // MARK: - Plumbing

    /// `grp/sub/proj` → `grp%2Fsub%2Fproj`, the id form GitLab accepts.
    static func encodePathSegment(_ path: String) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return path.addingPercentEncoding(withAllowedCharacters: allowed) ?? path
    }

    /// Follows `X-Next-Page` through every page (bounded).
    private func paged<T: Decodable>(_ path: String, _ query: [URLQueryItem], what: String) async throws -> [T] {
        var all: [T] = []
        var page = "1"
        for _ in 0..<50 {
            let (data, response) = try await send(
                "GET", path,
                query + [URLQueryItem(name: "per_page", value: "100"), URLQueryItem(name: "page", value: page)])
            let batch: [T] = try decode(data, what)
            all.append(contentsOf: batch)
            guard let next = response.value(forHTTPHeaderField: "X-Next-Page"), !next.isEmpty, !batch.isEmpty else {
                break
            }
            page = next
        }
        return all
    }

    private func decode<T: Decodable>(_ data: Data, _ what: String) throws -> T {
        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            throw ForgeAPIError.decoding(forge: .gitlab, what: "\(what): \(error.localizedDescription)")
        }
    }

    /// Sends with the shared transport: retry on transient failures (network
    /// errors, 429, 5xx) and the common status→error mapping.
    func send(
        _ method: String, _ path: String, _ query: [URLQueryItem] = [], body: Data? = nil,
        accept: String = "application/json"
    ) async throws -> (Data, HTTPURLResponse) {
        let result = try await transport.send(method, try url(path, query), body: body, accept: accept)
        if let limit = ForgeRateLimit(headers: result.1) { rateLimits.record(limit) }
        return result
    }

    func url(_ path: String, _ query: [URLQueryItem]) throws -> URL {
        let base = try GitLabCredentials.validate(
            instance: credentials.instance, allowInsecureHTTP: credentials.allowInsecureHTTP)
        guard var components = URLComponents(url: base, resolvingAgainstBaseURL: false) else {
            throw GitLabError.invalidInstance(credentials.instance)
        }
        var prefix = components.percentEncodedPath
        while prefix.hasSuffix("/") { prefix.removeLast() }
        // `path` is already percent-encoded (nested scope ids carry %2F).
        components.percentEncodedPath = prefix + "/api/v4" + path
        components.queryItems = query.isEmpty ? nil : query
        guard let url = components.url else {
            throw GitLabError.invalidInstance(credentials.instance)
        }
        return url
    }
}

/// A project id and its `path_with_namespace`.
struct GitLabProjectRef: Decodable, Sendable, Equatable {
    let id: Int
    let path: String

    init(id: Int, path: String) {
        self.id = id
        self.path = path
    }

    enum CodingKeys: String, CodingKey {
        case id
        case path = "path_with_namespace"
    }
}
