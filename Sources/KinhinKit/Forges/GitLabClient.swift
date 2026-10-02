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
    let session: URLSession
    /// Projects polled per read of a group's jobs.
    let maxProjectsPerPoll = 50
    /// Concurrent per-project job reads.
    let maxConcurrentReads = 8
    /// How long a group's project list is reused.
    let projectListTTL: TimeInterval = 300
    /// Projects without activity for this long are not polled for jobs.
    let activityWindow: TimeInterval = 24 * 3600
    /// stdlib `Mutex` is non-Copyable, so a struct cannot store one directly;
    /// the cache lives in a shared class box instead.
    private let projectCache = ProjectListCache()

    /// Reference cell for the group project list plus its fetch time.
    private final class ProjectListCache: Sendable {
        let mutex = Mutex<(fetched: Date, projects: [GitLabProjectRef])?>(nil)
    }

    public init(credentials: GitLabCredentials, session: URLSession? = nil) {
        self.credentials = credentials
        self.session = ForgeHTTP.session(session)
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
        } catch GitLabError.notFound {
            // Not a project (or not visible as one): try the group below.
        }
        do {
            let (data, _) = try await send("GET", "/groups/\(encoded)")
            struct Group: Decodable { let id: Int; let full_path: String }
            let group: Group = try decode(data, "group")
            return .group(id: group.id, path: group.full_path)
        } catch GitLabError.notFound {
            throw GitLabError.notFound("project or group '\(credentials.scope)'")
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

    /// The scope's jobs with the given status, attributed to their project.
    /// A project the token cannot read (403/404) is skipped rather than
    /// failing the whole read: it contributes no jobs kinhin could run.
    func jobs(_ status: JobStatus, in scope: GitLabScope) async throws -> [GitLabJob] {
        let projects = try await projects(in: scope)
        return try await withThrowingTaskGroup(of: [GitLabJob].self) { group in
            var remaining = projects.prefix(maxProjectsPerPoll).makeIterator()
            func addNext() -> Bool {
                guard let project = remaining.next() else { return false }
                group.addTask { try await jobs(status, project: project) }
                return true
            }
            for _ in 0..<maxConcurrentReads {
                guard addNext() else { break }
            }
            var all: [GitLabJob] = []
            while let batch = try await group.next() {
                all.append(contentsOf: batch)
                _ = addNext()
            }
            return all.sorted { $0.id < $1.id }
        }
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
            struct Pipeline: Decodable { let id: Int? }
            struct Runner: Decodable { let description: String? }
            struct Commit: Decodable { let id: String? }
        }
        do {
            let (data, _) = try await send(
                "GET", "/projects/\(project.id)/jobs",
                [URLQueryItem(name: "scope[]", value: status.rawValue), URLQueryItem(name: "per_page", value: "100")])
            let jobs: [Job] = try decode(data, "jobs")
            return jobs.map {
                GitLabJob(
                    id: $0.id, name: $0.name, tags: $0.tag_list ?? [], project: project.path,
                    runnerDescription: $0.runner?.description, ref: $0.ref, sha: $0.commit?.id,
                    projectID: project.id, pipelineID: $0.pipeline?.id)
            }
        } catch GitLabError.notFound, GitLabError.forbidden {
            Log.warn("gitlab", "skipping jobs of \(project.path): not readable with this token")
            return []
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
            throw GitLabError.decoding("\(what): \(error.localizedDescription)")
        }
    }

    /// Sends with retry on transient failures (network errors, 429, 5xx).
    func send(
        _ method: String, _ path: String, _ query: [URLQueryItem] = [], body: Data? = nil,
        accept: String = "application/json"
    ) async throws -> (Data, HTTPURLResponse) {
        try await withTransientRetry(isTransient: Self.isTransient) {
            try await sendOnce(method, path, query, body: body, accept: accept)
        }
    }

    static func isTransient(_ error: Error) -> Bool {
        if case .http(let code, _) = error as? GitLabError { return ForgeHTTP.isTransientStatus(code) }
        return ForgeHTTP.isTransientNetworkError(error)
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

    private func sendOnce(
        _ method: String, _ path: String, _ query: [URLQueryItem], body: Data?, accept: String
    ) async throws -> (Data, HTTPURLResponse) {
        var req = URLRequest(url: try url(path, query))
        req.httpMethod = method
        req.setValue(credentials.token, forHTTPHeaderField: "PRIVATE-TOKEN")
        req.setValue(accept, forHTTPHeaderField: "Accept")
        req.setValue("Kinhin/1.0", forHTTPHeaderField: "User-Agent")
        if let body {
            req.httpBody = body
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        let (data, response) = try await session.data(for: req)
        guard let http = response as? HTTPURLResponse else {
            throw GitLabError.http(0, "non-HTTP response")
        }
        switch http.statusCode {
        case 200...299:
            return (data, http)
        case 401:
            throw GitLabError.unauthorized
        case 403:
            throw GitLabError.forbidden(String(decoding: data.prefix(300), as: UTF8.self))
        case 404:
            throw GitLabError.notFound(path)
        default:
            throw GitLabError.http(http.statusCode, String(decoding: data.prefix(300), as: UTF8.self))
        }
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
