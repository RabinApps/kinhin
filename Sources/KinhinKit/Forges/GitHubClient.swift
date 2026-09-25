import Foundation

public struct GitHubCredentials: Sendable {
    public let token: String
    /// GitHub scope the fleet serves: "RabinApps/name" (one repository) or a
    /// single "org" segment (an entire organization — runners register at
    /// the org level and serve every repo's queued jobs).
    public let scope: String

    public init(token: String, scope: String) {
        self.token = token
        self.scope = scope
    }

    /// True when the scope is an organization, not a single repository.
    var isOrgScope: Bool { !scope.contains("/") }

    /// The owner segment of the scope ("RabinApps" in "RabinApps/name").
    public var owner: String { String(scope.split(separator: "/").first ?? "") }

    /// URL passed to the runner's `config.sh --url`. Org-level runners
    /// register at /organizations/<org>, repo-level at /<RabinApps>/<repo>.
    var configureURL: String {
        isOrgScope
            ? "https://github.com/organizations/\(scope)"
            : "https://github.com/\(scope)"
    }

    /// REST path prefix for the Actions API of this scope.
    var actionsBase: String {
        isOrgScope
            ? "/orgs/\(scope)/actions"
            : "/repos/\(scope)/actions"
    }
}

public enum GitHubError: LocalizedError, Equatable {
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

// MARK: - Models

public struct GHLabel: Codable, Sendable, Equatable {
    public let name: String
}

public struct GHRunner: Codable, Sendable, Equatable {
    public let id: Int
    public let name: String
    public let status: String  // "online" | "offline"
    public let busy: Bool
    public let labels: [GHLabel]?

}

public struct GHJob: Codable, Sendable, Equatable {
    public let id: Int
    let runID: Int
    public let name: String
    public let status: String
    public let labels: [String]?
    /// The runner executing (or slated to execute) this job — the key that
    /// maps a running job back to one of our VMs.
    let runnerName: String?

    enum CodingKeys: String, CodingKey {
        case id, name, status, labels
        case runID = "run_id"
        case runnerName = "runner_name"
    }
}

/// A job currently executing on a runner (per-repo attribution of running
/// work in org scope). `runnerName` is what the runner registered as.
public struct RunningJob: Sendable, Equatable {
    public let name: String
    let runnerName: String?
    public let repository: String?

    public init(name: String, runnerName: String?, repository: String?) {
        self.name = name
        self.runnerName = runnerName
        self.repository = repository
    }
}

/// A queued job that this fleet could run.
public struct QueuedJob: Sendable, Equatable {
    let runID: Int
    let jobID: Int
    public let name: String
    public let labels: [String]
    /// Repository the job belongs to (always present in org scope; nil when
    /// the API response didn't include it).
    public let repository: String?

    public init(runID: Int, jobID: Int, name: String, labels: [String], repository: String? = nil) {
        self.runID = runID
        self.jobID = jobID
        self.name = name
        self.labels = labels
        self.repository = repository
    }
}

public struct RegistrationToken: Codable, Sendable, Equatable {
    public let token: String
    let expiresAt: Date
}

/// A repository visible to the stored token — one pickable target for the
/// onboarding repo step and the Config tab's repo picker.
public struct RepoRef: Sendable, Equatable, Identifiable {
    public let fullName: String
    let isPrivate: Bool
    /// nil when the API didn't say (old Gitea versions).
    let hasActionsEnabled: Bool?

    public var id: String { fullName }

    public init(fullName: String, isPrivate: Bool = false, hasActionsEnabled: Bool? = nil) {
        self.fullName = fullName
        self.isPrivate = isPrivate
        self.hasActionsEnabled = hasActionsEnabled
    }
}

// MARK: - Client

/// Minimal GitHub REST client covering what the autoscaler needs.
public protocol GitHubServing: Sendable {
    /// The URL the VM's `config.sh --url` must use for this scope
    /// (organizations register at github.com/organizations/<org>).
    var configureURL: String { get }
    func fetchRegistrationToken() async throws -> RegistrationToken
    func listRunners() async throws -> [GHRunner]
    func deleteRunner(id: Int) async throws
    func queuedJobs(matching labels: Set<String>) async throws -> [QueuedJob]
    func runningJobs(matching labels: Set<String>) async throws -> [RunningJob]
}

public struct GitHubClient: GitHubServing {
    let credentials: GitHubCredentials
    let session: URLSession

    public var configureURL: String { credentials.configureURL }

    public init(credentials: GitHubCredentials, session: URLSession? = nil) {
        self.credentials = credentials
        if let session {
            self.session = session
        } else {
            let config = URLSessionConfiguration.default
            config.timeoutIntervalForRequest = 30
            config.timeoutIntervalForResource = 60
            config.waitsForConnectivity = false
            self.session = URLSession(configuration: config)
        }
    }

    // MARK: Plumbing

    func request(method: String, path: String, body: Data? = nil) throws -> URLRequest {
        let segments = credentials.scope.split(separator: "/")
        // A scope-less client is only for token-level calls (listing the repos
        // the token can see during onboarding); everything else needs a scope.
        let tokenLevel = credentials.scope.isEmpty && path.hasPrefix("/user/")
        guard
            tokenLevel
                || ((segments.count == 1 || segments.count == 2)
                    && segments.allSatisfy({ !$0.isEmpty }))
        else {
            throw GitHubError.http(0, "invalid scope spec \(credentials.scope) — use 'RabinApps/name' or an org name")
        }
        var req = URLRequest(url: URL(string: "https://api.github.com\(path)")!)
        req.httpMethod = method
        req.httpBody = body
        req.setValue("Bearer \(credentials.token)", forHTTPHeaderField: "Authorization")
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        req.setValue("Kinhin/1.0", forHTTPHeaderField: "User-Agent")
        req.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        return req
    }

    /// Execute with retry on transient failures, honoring rate-limit headers.
    func send(_ req: URLRequest, retries: Int = 3) async throws -> (Data, HTTPURLResponse) {
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
                switch http.statusCode {
                case 200...299:
                    return (data, http)
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
                case 500...599:
                    lastError = GitHubError.http(http.statusCode, String(decoding: data.prefix(500), as: UTF8.self))
                    continue
                default:
                    throw GitHubError.http(http.statusCode, String(decoding: data.prefix(500), as: UTF8.self))
                }
            } catch let error as GitHubError {
                // Only retryable classes continue the loop.
                if case .forbidden = error { lastError = error; continue }
                if case .http(let code, _) = error, code >= 500 { lastError = error; continue }
                if case .http(0, _) = error { lastError = error; continue }
                throw error
            } catch {
                // Network-layer error (offline, DNS, timeout): retry.
                lastError = GitHubError.http(0, error.localizedDescription)
                continue
            }
        }
        throw lastError
    }

    // MARK: API

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
        _ = try await send(req)
    }

    /// Fetch all queued workflow runs, then their jobs, filtering client-side
    /// to jobs whose label set is a superset of the fleet's labels.
    public func queuedJobs(matching labels: Set<String>) async throws -> [QueuedJob] {
        let queuedRuns = try await fetchRuns(status: "queued")

        var jobs: [QueuedJob] = []
        for run in queuedRuns.prefix(50) {  // safety bound on fan-out per poll
            for job in try await fetchJobs(runID: run.id) where job.status == "queued" {
                let jobLabels = Set(job.labels ?? [])
                if labels.isSubset(of: jobLabels) {
                    jobs.append(
                        QueuedJob(
                            runID: run.id, jobID: job.id, name: job.name,
                            labels: jobLabels.sorted(), repository: run.repository?.full_name
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
        let activeRuns = try await fetchRuns(status: "in_progress")

        var jobs: [RunningJob] = []
        for run in activeRuns.prefix(50) {  // same safety bound as queued
            for job in try await fetchJobs(runID: run.id) where job.status == "in_progress" {
                let jobLabels = Set(job.labels ?? [])
                if labels.isSubset(of: jobLabels) {
                    jobs.append(
                        RunningJob(
                            name: job.name, runnerName: job.runnerName,
                            repository: run.repository?.full_name
                        ))
                }
            }
        }
        return jobs
    }

    /// All runs in the scope with the given status, following pagination.
    private func fetchRuns(status: String) async throws -> [RunSummary] {
        var runs: [RunSummary] = []
        var page = 1
        while true {
            let req = try request(
                method: "GET",
                path: "\(credentials.actionsBase)/runs?status=\(status)&per_page=100&page=\(page)"
            )
            let (data, _) = try await send(req)
            do {
                let decoded = try JSONDecoder().decode(RunsResponse.self, from: data)
                runs.append(contentsOf: decoded.workflow_runs)
                let totalPages = (decoded.total_count + 99) / 100
                if page >= max(totalPages, 1) || decoded.workflow_runs.isEmpty { break }
                page += 1
            } catch {
                throw GitHubError.decoding("runs: \(error.localizedDescription)")
            }
        }
        return runs
    }

    /// All jobs of one workflow run.
    private func fetchJobs(runID: Int) async throws -> [GHJob] {
        let req = try request(
            method: "GET",
            path: "\(credentials.actionsBase)/runs/\(runID)/jobs?per_page=100"
        )
        let (data, _) = try await send(req)
        do {
            return try JSONDecoder().decode(JobsResponse.self, from: data).jobs
        } catch {
            throw GitHubError.decoding("jobs: \(error.localizedDescription)")
        }
    }

    struct RunSummary: Codable {
        let id: Int
        let repository: RepoSummary?
    }

    /// Nested repo object inside workflow-run payloads (distinct from the
    /// public RepoRef picker model).
    struct RepoSummary: Codable {
        let full_name: String
    }

    struct RunsResponse: Codable {
        let total_count: Int
        let workflow_runs: [RunSummary]
    }

    struct JobsResponse: Codable {
        let jobs: [GHJob]
    }
}

extension JSONDecoder {
    static var registrationDate: JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }
}
