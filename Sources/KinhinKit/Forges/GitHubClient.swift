import Foundation

public struct GitHubCredentials: Sendable {
    public let token: String
    /// GitHub scope the fleet serves: "owner/name" (one repository) or a
    /// single "org" segment (an entire organization — runners register at
    /// the org level and serve every repo's queued jobs).
    public let scope: String

    public init(token: String, scope: String) {
        self.token = token
        self.scope = scope
    }

    /// True when the scope is an organization, not a single repository.
    var isOrgScope: Bool { !scope.contains("/") }

    /// The owner segment of the scope ("acme" in "acme/api").
    public var owner: String { String(scope.split(separator: "/").first ?? "") }

    /// URL passed to the runner's `config.sh --url`: GitHub's documented form
    /// is `https://github.com/<org>` for org runners and
    /// `https://github.com/<owner>/<repo>` for repo runners (the
    /// `/organizations/<org>` form answers 404 from runner-registration).
    var configureURL: String { "https://github.com/\(scope)" }

    /// REST path prefix for the Actions API of this scope.
    var actionsBase: String {
        isOrgScope
            ? "/orgs/\(scope)/actions"
            : "/repos/\(scope)/actions"
    }
}

public enum GitHubError: LocalizedError, Equatable, Sendable {
    case unauthorized
    case forbidden(String)
    case notFound(String)
    case rateLimited(resetAt: Date)
    case http(Int, String)
    case decoding(String)

    public var errorDescription: String? {
        switch self {
        case .unauthorized:
            return
                "GitHub rejected the token (401). Check it with `kinhin auth status` — it may be expired or lack the required scopes."
        case .forbidden(let why):
            return "GitHub forbidden (403): \(why)"
        case .notFound(let what):
            if what.hasPrefix("/orgs/"), what.contains("/actions/runs") {
                return
                    "GitHub returned 404 for \(what): the token cannot read this organization's workflow runs. "
                    + "Kinhin reads runs per repository; check the token's repository access and Actions: Read-only permission."
            }
            if what.hasSuffix("/*/actions/runs") {
                return
                    "GitHub returned 404 for \(what): the token cannot read workflow runs in any repository of the scope. "
                    + "Fine-grained tokens need Repository permissions → Actions: Read-only; a classic token with the repo scope always works."
            }
            return "GitHub returned 404 for \(what). Does the repo exist and does the token have access to it?"
        case .rateLimited(let resetAt):
            return "GitHub rate limit exhausted; resets at \(resetAt)"
        case .http(let code, let body):
            return "GitHub HTTP \(code): \(body)"
        case .decoding(let why):
            return "Could not decode GitHub response: \(why)"
        }
    }
}

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
    /// The API budget the last response reported; nil when unknown.
    var rateLimit: ForgeRateLimit? { get }
    /// `.kinhin.yml` of `repository` at `ref` (nil = default branch), or nil
    /// when the repository has none.
    func projectFile(repository: String, ref: String?) async throws -> Data?
    /// The in-progress job `runnerName` is executing, with its steps.
    func pipelineDetail(runnerName: String) async throws -> PipelineDetail?
}

extension GitHubServing {
    public var rateLimit: ForgeRateLimit? { nil }
    public func pipelineDetail(runnerName: String) async throws -> PipelineDetail? { nil }
    public func projectFile(repository: String, ref: String?) async throws -> Data? { nil }
}

public struct GitHubClient: GitHubServing {
    let credentials: GitHubCredentials
    let session: URLSession

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
        guard let url = URL(string: "https://api.github.com\(path)") else {
            throw GitHubError.http(0, "invalid request path \(path)")
        }
        var req = URLRequest(url: url)
        req.httpMethod = method
        req.httpBody = body
        req.setValue("Bearer \(credentials.token)", forHTTPHeaderField: "Authorization")
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        req.setValue("Kinhin/1.0", forHTTPHeaderField: "User-Agent")
        req.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        return req
    }

    /// Execute with retry on transient failures, honoring rate-limit headers.
    /// GETs revalidate against `conditionalGets`: a 304 returns the cached
    /// body, so callers never see the difference.
    func send(_ req: URLRequest, retries: Int = 3) async throws -> (Data, HTTPURLResponse) {
        var req = req
        let conditionalKey = req.httpMethod == "GET" ? req.url?.absoluteString : nil
        if let conditionalKey, let etag = conditionalGets.etag(for: conditionalKey) {
            req.setValue(etag, forHTTPHeaderField: "If-None-Match")
        }
        var attempt = 0
        var lastError: Error = GitHubError.http(0, "no attempt made")
        while attempt <= retries {
            if attempt > 0 {
                try await Task.sleep(for: .seconds(min(8.0, pow(2, Double(attempt)))))
            }
            attempt += 1
            do {
                let (data, response) = try await session.data(for: req)
                guard let http = response as? HTTPURLResponse else {
                    lastError = GitHubError.http(0, "non-HTTP response")
                    continue
                }
                if let limit = ForgeRateLimit(headers: http) { rateLimits.record(limit) }
                switch http.statusCode {
                case 200...299:
                    if let conditionalKey, let etag = http.value(forHTTPHeaderField: "ETag") {
                        conditionalGets.store(url: conditionalKey, etag: etag, body: data)
                    }
                    return (data, http)
                case 304:
                    if let conditionalKey, let body = conditionalGets.body(for: conditionalKey) {
                        return (body, http)
                    }
                    // The cached body was evicted mid-flight: read it afresh.
                    req.setValue(nil, forHTTPHeaderField: "If-None-Match")
                    lastError = GitHubError.http(304, "not modified, but no cached body")
                    continue
                case 401:
                    throw GitHubError.unauthorized
                case 403:
                    if let remaining = http.value(forHTTPHeaderField: "X-RateLimit-Remaining"),
                        remaining == "0",
                        let resetStr = http.value(forHTTPHeaderField: "X-RateLimit-Reset"),
                        let reset = TimeInterval(resetStr)
                    {
                        throw GitHubError.rateLimited(resetAt: Date(timeIntervalSince1970: reset))
                    }
                    lastError = GitHubError.forbidden(String(decoding: data.prefix(500), as: UTF8.self))
                    continue  // can be transient (secondary limits)
                case 404:
                    throw GitHubError.notFound(req.url?.path ?? "resource")
                case 429, 500...599:
                    lastError = GitHubError.http(http.statusCode, String(decoding: data.prefix(500), as: UTF8.self))
                    continue
                default:
                    throw GitHubError.http(http.statusCode, String(decoding: data.prefix(500), as: UTF8.self))
                }
            } catch let error as GitHubError {
                // Only retryable classes continue the loop.
                if case .forbidden = error { lastError = error; continue }
                if case .http(let code, _) = error, code == 429 || code >= 500 { lastError = error; continue }
                if case .http(0, _) = error { lastError = error; continue }
                throw error
            } catch let error where ForgeHTTP.isTransientNetworkError(error) {
                // Network-layer error (offline, DNS, timeout): retry.
                lastError = GitHubError.http(0, error.localizedDescription)
                continue
            } catch let error as URLError where error.code == .cancelled {
                // A cancelled request surfaces as URLError; it must end the
                // caller's task like any other cancellation, never retry.
                throw CancellationError()
            }
        }
        throw lastError
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

    /// Fetch all queued workflow runs, then their jobs, filtering client-side
    /// to jobs whose label set is a superset of the fleet's labels.
    public func queuedJobs(matching labels: Set<String>) async throws -> [QueuedJob] {
        var jobs: [QueuedJob] = []
        for run in try await runs(status: "queued") {
            for job in try await fetchJobs(runID: run.id, repository: run.scopedRepository) where job.status == "queued"
            {
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

    /// Fetch jobs currently executing on this scope's runners. `runnerName`
    /// maps each job back to the VM that registered that runner — the basis
    /// for per-repo attribution of running work.
    public func runningJobs(matching labels: Set<String>) async throws -> [RunningJob] {
        var jobs: [RunningJob] = []
        for run in try await runs(status: "in_progress") {
            for job in try await fetchJobs(runID: run.id, repository: run.scopedRepository)
            where job.status == "in_progress" {
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
}

extension JSONDecoder {
    static var registrationDate: JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }
}
