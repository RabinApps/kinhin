import Foundation

// MARK: - Client

/// Minimal GitHub REST client covering what the autoscaler needs.
public protocol GitHubServing: Sendable {
    /// The URL the VM's `config.sh --url` must use for this scope
    /// (organizations register at github.com/<org>).
    var configureURL: String { get }
    func fetchRegistrationToken() async throws -> RegistrationToken
    func listRunners() async throws -> [GHRunner]
    func deleteRunner(id: Int) async throws
    func queuedJobs(matching labels: Set<String>) async throws -> [QueuedJob]
    func runningJobs(matching labels: Set<String>) async throws -> [RunningJob]
    /// Cancel the queued workflow runs `ids` (their jobs are re-queued
    /// downstream). Nil when none is found or the caller cannot cancel them.
    func cancelWorkflowRun(ids: [Int]) async throws -> Bool
    /// Mark the queued workflow runs `ids` as skipped (their jobs are
    /// dropped). Nil when none is found or the caller cannot skip them.
    func skipWorkflowRun(ids: [Int]) async throws -> Bool
    /// The API budget the last response reported; nil when unknown.
    var rateLimit: ForgeRateLimit? { get }
    /// `.kinhin.yml` of `repository` at `ref` (nil = default branch), or nil
    /// when the repository has none.
    func projectFile(repository: String, ref: String?) async throws -> Data?
    /// The in-progress job `runnerName` is executing, with its steps.
    func pipelineDetail(runnerName: String) async throws -> PipelineDetail?
    /// The raw log of one job (`owner/name`, job id) so far; nil when the
    /// client can't read logs.
    func jobLog(repository: String, jobID: Int) async throws -> String?
}

extension GitHubServing {
    public var rateLimit: ForgeRateLimit? { nil }
    public func pipelineDetail(runnerName: String) async throws -> PipelineDetail? { nil }
    public func jobLog(repository: String, jobID: Int) async throws -> String? { nil }
    public func projectFile(repository: String, ref: String?) async throws -> Data? { nil }
}

public struct GitHubClient: GitHubServing {
    let credentials: GitHubCredentials
    let session: URLSession
    /// The retry policy for every request (tests shorten the waits).
    var retryPolicy = ForgeRetryPolicy(retries: 3)

    public var configureURL: String { credentials.configureURL }

    /// The scope's runner list, shared briefly: every live instance's exit
    /// watch lists runners each second, and the fleet must cost one call per
    /// few seconds, not one per instance per second.
    let runnerCache = SharedListCache<GHRunner>(ttl: 3)
    /// Repositories read in per-repository fallback mode. Two runs reads per
    /// poll would otherwise re-list the scope's repositories each time; new
    /// repositories are picked up within this TTL.
    let scopeRepoCache = SharedListCache<String>(ttl: 300)
    /// ETags of recent reads, so unchanged polls come back as free 304s.
    let conditionalGets = ConditionalGetCache()
    let rateLimits = RateLimitBox()

    public var rateLimit: ForgeRateLimit? { rateLimits.current }

    /// Fan-out bounds per poll, same safety bound as the jobs loops: at most
    /// this many repositories and workflow runs are read per poll when the
    /// per-repository fallback is active.
    var maxReposPerPoll: Int { 20 }
    var maxRunsPerPoll: Int { 50 }

    public init(credentials: GitHubCredentials, session: URLSession? = nil) {
        self.credentials = credentials
        self.session = ForgeHTTP.session(session)
    }

    // MARK: - Plumbing

    /// A GitHub owner or repository name: letters, digits, `.`, `_`, `-`, and
    /// never `.`/`..` (the scope is spliced into the request path).
    static func isValidScopeSegment(_ segment: Substring) -> Bool {
        !segment.isEmpty && segment != "." && segment != ".."
            && segment.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "." || $0 == "_" || $0 == "-") }
    }

    func request(method: String, path: String, body: Data? = nil) throws -> URLRequest {
        let segments = credentials.scope.split(separator: "/")
        // A scope-less client is only for token-level calls (listing the repos
        // the token can see during onboarding); everything else needs a scope.
        let tokenLevel = credentials.scope.isEmpty && path.hasPrefix("/user/")
        guard
            tokenLevel
                || ((segments.count == 1 || segments.count == 2)
                    && segments.allSatisfy(Self.isValidScopeSegment))
        else {
            throw GitHubError.http(0, "invalid scope spec \(credentials.scope) — use 'owner/name' or an org name")
        }
        let apiBase = credentials.apiBase
        guard let url = URL(string: apiBase + path) else {
            throw GitHubError.http(0, "invalid request path \(path)")
        }
        // GHES instances answer on `<host>/api/v3`; pagination and any
        // redirect targets must stay on that host (the shared
        // `ForgeHTTP.allowsRedirect` rule already enforces same-host
        // redirects and blocks https→http downgrades).
        var req = URLRequest(url: url)
        req.httpMethod = method
        req.httpBody = body
        req.setValue("Bearer \(credentials.token)", forHTTPHeaderField: "Authorization")
        GitHubAPI.apply(to: &req)
        return req
    }

    /// Execute under the shared `ForgeRetryPolicy`: network errors, 5xx and real
    /// rate limits (429, or a 403 carrying `Retry-After` / a spent budget) are
    /// retried; a plain 403 is a permissions error and surfaces at once.
    /// GETs revalidate against `conditionalGets`: a 304 returns the cached
    /// body, so callers never see the difference.
    func send(_ req: URLRequest, retries: Int? = nil) async throws -> (Data, HTTPURLResponse) {
        var request = req
        var policy = retryPolicy
        if let retries { policy.retries = retries }
        let conditionalKey = request.httpMethod == "GET" ? request.url?.absoluteString : nil
        if let conditionalKey, let etag = conditionalGets.etag(for: conditionalKey) {
            request.setValue(etag, forHTTPHeaderField: "If-None-Match")
        }
        return try await policy.run { () async throws -> ForgeRetryPolicy.Attempt<(Data, HTTPURLResponse)> in
            let (data, response): (Data, URLResponse)
            do {
                (data, response) = try await session.data(for: request)
            } catch let error where ForgeHTTP.isTransientNetworkError(error) {
                return .retry(GitHubError.http(0, error.localizedDescription), after: nil)
            }
            guard let http = response as? HTTPURLResponse else {
                return .retry(GitHubError.http(0, "non-HTTP response"), after: nil)
            }
            if let limit = ForgeRateLimit(headers: http) { rateLimits.record(limit) }
            if (200...299).contains(http.statusCode) {
                if let conditionalKey, let etag = http.value(forHTTPHeaderField: "ETag") {
                    conditionalGets.store(url: conditionalKey, etag: etag, body: data)
                }
                return .done((data, http))
            }
            if http.statusCode == 304 {
                if let conditionalKey, let body = conditionalGets.body(for: conditionalKey) {
                    return .done((body, http))
                }
                // The cached body was evicted mid-flight: read it afresh.
                request.setValue(nil, forHTTPHeaderField: "If-None-Match")
                return .retry(GitHubError.http(304, "not modified, but no cached body"), after: nil)
            }
            let failure = GitHubError.from(http, body: data, path: request.url?.path ?? "resource")
            if case .retry(let after) = policy.verdict(for: http) { return .retry(failure, after: after) }
            throw failure
        }
    }

    // MARK: - API

    public func fetchRegistrationToken() async throws -> RegistrationToken {
        let req = try request(method: "POST", path: "\(credentials.actionsBase)/runners/registration-token")
        let (data, _) = try await send(req)
        do {
            let decoded = try JSONDecoder.registrationDate.decode(RegistrationTokenResponse.self, from: data)
            return RegistrationToken(token: decoded.token, expiresAt: decoded.expires_at)
        } catch {
            throw GitHubError.decoding("registration-token: \(error.localizedDescription)")
        }
    }

    struct RegistrationTokenResponse: Codable {
        let token: String
        let expires_at: Date
    }

    /// Repos the token can see, for the onboarding/Config repo pickers.
    /// An empty scope lists everything the token can access; repo scopes
    /// list siblings of that repo; org scopes list the org's repos. Actions-enabled repos sort first, then by name.
    public func listRepositories() async throws -> [RepoRef] {
        var refs: [RepoRef] = []
        var page = 1
        while true {
            let path: String
            if credentials.scope.isEmpty {
                // No scope yet (onboarding): list every repo the token can
                // see — its own, collaborator, and org repos.
                path =
                    "/user/repos?per_page=100&page=\(page)&sort=full_name&affiliation=owner,collaborator,organization_member"
            } else if credentials.isOrgScope {
                path = "/orgs/\(credentials.scope)/repos?per_page=100&page=\(page)"
            } else {
                path = "/users/\(credentials.owner)/repos?per_page=100&page=\(page)&sort=full_name"
            }
            let req = try request(method: "GET", path: path)
            let (data, _) = try await send(req)
            struct GHRepo: Decodable {
                let full_name: String
                let isPrivate: Bool
                let has_actions: Bool?

                init(from decoder: Decoder) throws {
                    let c = try decoder.container(keyedBy: CodingKeys.self)
                    full_name = try c.decode(String.self, forKey: .full_name)
                    isPrivate = try c.decodeIfPresent(Bool.self, forKey: .isPrivate) ?? false
                    has_actions = try c.decodeIfPresent(Bool.self, forKey: .has_actions)
                }

                enum CodingKeys: String, CodingKey {
                    case full_name
                    case isPrivate = "private"
                    case has_actions
                }
            }
            let batch: [GHRepo]
            do { batch = try JSONDecoder().decode([GHRepo].self, from: data) } catch {
                throw GitHubError.decoding("repos: \(error.localizedDescription)")
            }
            refs.append(
                contentsOf: batch.map {
                    RepoRef(fullName: $0.full_name, isPrivate: $0.isPrivate, hasActionsEnabled: $0.has_actions)
                })
            if batch.count < 100 { break }
            page += 1
        }
        return refs.sorted {
            if ($0.hasActionsEnabled ?? true) != ($1.hasActionsEnabled ?? true) {
                return $0.hasActionsEnabled ?? true
            }
            return $0.fullName.localizedCaseInsensitiveCompare($1.fullName) == .orderedAscending
        }
    }

    public func listRunners() async throws -> [GHRunner] {
        try await runnerCache.elements(fetch: fetchRunners)
    }

    func fetchRunners() async throws -> [GHRunner] {
        var all: [GHRunner] = []
        var page = 1
        while true {
            let req = try request(method: "GET", path: "\(credentials.actionsBase)/runners?per_page=100&page=\(page)")
            let (data, _) = try await send(req)
            do {
                let decoded = try JSONDecoder().decode(RunnerListResponse.self, from: data)
                all.append(contentsOf: decoded.runners)
                let totalPages = (decoded.total_count + 99) / 100
                if page >= max(totalPages, 1) || decoded.runners.isEmpty { break }
                page += 1
            } catch {
                throw GitHubError.decoding("runners: \(error.localizedDescription)")
            }
        }
        return all
    }

    struct RunnerListResponse: Codable {
        let total_count: Int
        let runners: [GHRunner]
    }

    public func deleteRunner(id: Int) async throws {
        let req = try request(method: "DELETE", path: "\(credentials.actionsBase)/runners/\(id)")
        defer { runnerCache.invalidate() }  // the deleted runner must drop out of the next list
        _ = try await send(req)
    }

    /// Per-run/per-repository reads in flight at once (bounded: GitHub's
    /// secondary rate limits punish bursts).
    var maxConcurrentReads: Int { 5 }

    /// Fetch all queued workflow runs, then their jobs, filtering client-side
    /// to jobs whose label set is a superset of the fleet's labels. The
    /// per-run job reads run concurrently; the result keeps run order.
    public func queuedJobs(matching labels: Set<String>) async throws -> [QueuedJob] {
        let runs = try await runs(status: "queued")
        let perRun = try await boundedMap(runs, limit: maxConcurrentReads) { run in
            try await self.fetchJobs(runID: run.id, repository: run.scopedRepository)
        }
        var jobs: [QueuedJob] = []
        for (run, runJobs) in zip(runs, perRun) {
            for job in runJobs where job.status == "queued" {
                let jobLabels = Set(job.labels ?? [])
                if labels.isSubset(of: jobLabels) {
                    jobs.append(
                        QueuedJob(
                            runID: run.id, jobID: job.id, name: job.name,
                            labels: jobLabels.sorted(), repository: run.attributedRepository,
                            ref: run.ref, sha: run.sha, isFork: run.isFork
                        ))
                }
            }
        }
        return jobs
    }

    /// The repository a queued run belongs to, or nil when the run can't be
    /// read. Org scope fans out per repository, so the scoped runs endpoint
    /// answers instead of the job payload.
    func runRepository(for id: Int) async throws -> String? {
        let runs = try await runs(status: "queued")
        guard let run = runs.first(where: { $0.id == id }) else { return nil }
        return run.attributedRepository
    }

    /// Fetch jobs currently executing on this scope's runners. `runnerName`
    /// maps each job back to the VM that registered that runner — the basis
    /// for per-repo attribution of running work.
    public func runningJobs(matching labels: Set<String>) async throws -> [RunningJob] {
        let runs = try await runs(status: "in_progress")
        let perRun = try await boundedMap(runs, limit: maxConcurrentReads) { run in
            try await self.fetchJobs(runID: run.id, repository: run.scopedRepository)
        }
        var jobs: [RunningJob] = []
        for (run, runJobs) in zip(runs, perRun) {
            for job in runJobs where job.status == "in_progress" {
                let jobLabels = Set(job.labels ?? [])
                if labels.isSubset(of: jobLabels) {
                    jobs.append(
                        RunningJob(
                            name: job.name, runnerName: job.runnerName,
                            repository: run.attributedRepository
                        ))
                }
            }
        }
        return jobs
    }

    /// Cancel the queued workflow runs `ids` (their jobs are re-queued
    /// downstream). Nil when none of the runs is found or the caller cannot
    /// cancel them.
    public func cancelWorkflowRun(ids: [Int]) async throws -> Bool {
        try await withThrowingTaskGroup(of: Bool.self) { group in
            for id in ids {
                group.addTask { try await self.cancelWorkflowRun(id: id) }
            }
            var allOk = true
            for try await ok in group {
                if !ok { allOk = false }
            }
            return allOk
        }
    }

    /// Mark the queued workflow run `id` as skipped (its jobs are dropped).
    /// Nil when none of the runs is found or the caller cannot skip them.
    public func skipWorkflowRun(ids: [Int]) async throws -> Bool {
        try await withThrowingTaskGroup(of: Bool.self) { group in
            for id in ids {
                group.addTask { try await self.skipWorkflowRun(id: id) }
            }
            var allOk = true
            for try await ok in group {
                if !ok { allOk = false }
            }
            return allOk
        }
    }

    private func cancelWorkflowRun(id: Int) async throws -> Bool {
        guard let repository = try await runRepository(for: id) else { return false }
        let req = try request(method: "POST", path: "/repos/\(repository)/actions/runs/\(id)/cancel")
        do {
            let (_, _) = try await send(req)
            return true
        } catch GitHubError.notFound {
            return false
        }
    }

    private func skipWorkflowRun(id: Int) async throws -> Bool {
        guard let repository = try await runRepository(for: id) else { return false }
        let req = try request(method: "POST", path: "/repos/\(repository)/actions/runs/\(id)/disable")
        do {
            let (_, _) = try await send(req)
            return true
        } catch GitHubError.notFound {
            return false
        }
    }
}

extension JSONDecoder {
    static var registrationDate: JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }
}
