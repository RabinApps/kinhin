import Foundation

#if canImport(FoundationNetworking)
    import FoundationNetworking
#endif

// MARK: - Credentials

/// One Gitea instance + scope ("owner/name" repo or bare org name).
public struct GiteaCredentials: Sendable {
    public let token: String
    public let scope: String
    /// Instance base URL, e.g. "https://gitea.example.com" (no /api suffix).
    public let instance: String
    /// The account opted in to plain `http://` (`allow_insecure_http`): the
    /// token then travels in cleartext. Redirect and pagination host checks
    /// still apply.
    public let allowInsecureHTTP: Bool

    public init(token: String, scope: String, instance: String, allowInsecureHTTP: Bool = false) {
        self.token = token
        self.scope = scope
        self.instance = instance
        self.allowInsecureHTTP = allowInsecureHTTP
    }

    var isOrgScope: Bool { !scope.contains("/") }

    public var owner: String { String(scope.split(separator: "/").first ?? "") }

    /// Base for the actions sub-API of this scope.
    var actionsBase: String {
        isOrgScope
            ? "/api/v1/orgs/\(scope)/actions"
            : "/api/v1/repos/\(scope)/actions"
    }

    /// URL the in-VM act_runner registers against (the instance itself).
    var registrationURL: String { instance }

    static func validate(instance: String, allowInsecureHTTP: Bool = false) throws -> URL {
        guard let url = URL(string: instance),
            ForgeHTTP.permitsScheme(of: url, allowInsecureHTTP: allowInsecureHTTP),
            let host = url.host, !host.isEmpty,
            url.path.isEmpty || url.path == "/"
        else {
            throw GiteaError.invalidInstance(instance)
        }
        return url
    }
}

// MARK: - Client

/// Minimal Gitea REST client covering what the fleet lifecycle needs:
/// registration-token minting, runner listing/deletion, and demand polling
/// with a documented floor fallback (Gitea's cross-scope queued reporting is
/// thinner than GitHub's; the floor keeps the autoscaler sane regardless).
public struct GiteaClient: Sendable {
    let credentials: GiteaCredentials
    let session: URLSession

    public init(credentials: GiteaCredentials, session: URLSession? = nil) {
        self.credentials = credentials
        self.session = ForgeHTTP.session(session)
    }

    // MARK: - Endpoints

    /// Mint a runner registration token for the scope. The same call doubles
    /// as the permission probe (free, idempotent, registers nothing).
    public func fetchRegistrationToken() async throws -> String {
        let (data, _) = try await send(path: "\(credentials.actionsBase)/runners/registration-token")
        do {
            struct TokenResponse: Decodable { let token: String }
            return try JSONDecoder().decode(TokenResponse.self, from: data).token
        } catch {
            throw GiteaError.decoding("registration-token: \(error.localizedDescription)")
        }
    }

    /// Repos the token can see (own + collaborator + org-affiliated, the
    /// same surface the web dashboard shows) for the repo pickers. Actions
    /// availability is not reported uniformly across Gitea versions, so it
    /// stays nil unless the instance provides it.
    public func listRepositories() async throws -> [RepoRef] {
        var refs: [RepoRef] = []
        var page = 1
        while true {
            let (data, _) = try await send(
                path: "/api/v1/repos/search?limit=50&private=true&sorted=updated&page=\(page)")
            struct SearchHit: Decodable { let ok: Bool? }
            struct GiteaRepo: Decodable {
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
            struct Wrapper: Decodable {
                let ok: Bool?
                let data: [GiteaRepo]?

                // Tolerate both object shapes: a wrapped {ok,data} body and
                // a bare top-level array (older Gitea). The bare-array case
                // routes through GiteaRepo.self-decoding via AnyDecodable
                // bridge: decode the array first, fall back on type error.
                init(from decoder: Decoder) throws {
                    // A keyed container probe (not a decode) picks the body
                    // shape: mapping → wrapped {ok,data}, array → bare list.
                    if let keyed = try? decoder.container(keyedBy: CodingKeys.self) {
                        ok = try keyed.decodeIfPresent(Bool.self, forKey: .ok)
                        data = try keyed.decodeIfPresent([GiteaRepo].self, forKey: .data)
                    } else {
                        // Bare array: surface a typed failure so the caller's
                        // fallback decodes [GiteaRepo] directly.
                        throw DecodingError.typeMismatch(
                            [GiteaRepo].self,
                            .init(
                                codingPath: decoder.codingPath,
                                debugDescription: "bare array response")
                        )
                    }
                }

                enum CodingKeys: String, CodingKey { case ok, data }
            }
            let batch: [GiteaRepo]
            do {
                // Shape probe: the wrapped decode throws on the bare-array
                // body, which the decode below handles. A real parse failure
                // in either shape still throws from here.
                if let wrapped = try? JSONDecoder().decode(Wrapper.self, from: data).data {
                    batch = wrapped
                } else {
                    // Some Gitea versions return a bare array.
                    batch = try JSONDecoder().decode([GiteaRepo].self, from: data)
                }
            } catch {
                throw GiteaError.decoding("repos/search: \(error.localizedDescription)")
            }
            refs.append(
                contentsOf: batch.map {
                    RepoRef(fullName: $0.full_name, isPrivate: $0.isPrivate, hasActionsEnabled: $0.has_actions)
                })
            if batch.count < 50 { break }
            page += 1
        }
        return refs.sorted {
            if ($0.hasActionsEnabled ?? true) != ($1.hasActionsEnabled ?? true) {
                return $0.hasActionsEnabled ?? true
            }
            return $0.fullName.localizedCaseInsensitiveCompare($1.fullName) == .orderedAscending
        }
    }

    public func listRunners() async throws -> [GiteaRunner] {
        let (data, _) = try await send(path: "\(credentials.actionsBase)/runners")
        do {
            struct Wrapper: Decodable { let total_count: Int; let runners: [GiteaRunner] }
            return try JSONDecoder().decode(Wrapper.self, from: data).runners
        } catch {
            // Some Gitea versions return a bare array.
            do {
                return try JSONDecoder().decode([GiteaRunner].self, from: data)
            } catch {
                throw GiteaError.decoding("runners: \(error.localizedDescription)")
            }
        }
    }

    func deleteRunner(id: Int) async throws {
        _ = try await send(path: "\(credentials.actionsBase)/runners/\(id)", method: "DELETE")
    }

    /// Pending demand. Primary: the scope's task queue endpoints (verified on
    /// the target instance in the field). Fallback when the API answers but
    /// reports nothing usable: caller applies the min_runners floor.
    func queuedTaskCount() async throws -> Int {
        let (data, _) = try await send(path: "\(credentials.actionsBase)/tasks?status=waiting&page=1&limit=50")
        struct TaskRef: Decodable {}
        struct Wrapper: Decodable { let total_count: Int; let entries: [TaskRef]? }
        do {
            return try JSONDecoder().decode(Wrapper.self, from: data).total_count
        } catch {
            throw GiteaError.decoding("tasks: \(error.localizedDescription)")
        }
    }

    // MARK: - Task queue (attribution)

    /// The scope's task queue with per-task attribution. Requests up to 50
    /// entries (the same cap the count endpoint polls); entries the instance
    /// renders in an unknown shape still contribute via `total_count`.
    func queuedTasks() async throws -> [GiteaTask] {
        try await tasks(status: "waiting")
    }

    /// Tasks currently executing on the scope. `runner_name` keys each task
    /// to the runner (and therefore VM) executing it, mirroring GitHub's
    /// running-job attribution.
    func runningTasks() async throws -> [GiteaTask] {
        try await tasks(status: "running")
    }

    private func tasks(status: String) async throws -> [GiteaTask] {
        let (data, _) = try await send(path: "\(credentials.actionsBase)/tasks?status=\(status)&page=1&limit=50")
        do {
            let wrapper = try JSONDecoder().decode(TaskQueueWrapper.self, from: data)
            return wrapper.tasks
        } catch {
            throw GiteaError.decoding("tasks: \(error.localizedDescription)")
        }
    }

    // MARK: - Plumbing

    /// Sends with retry on transient failures (network errors, 5xx), matching
    /// the GitHub client's resilience to blips.
    func send(path: String, method: String = "GET") async throws -> (Data, HTTPURLResponse) {
        try await withTransientRetry(isTransient: Self.isTransient) {
            try await sendOnce(path: path, method: method)
        }
    }

    static func isTransient(_ error: Error) -> Bool {
        if case .http(let code, _) = error as? GiteaError { return ForgeHTTP.isTransientStatus(code) }
        return ForgeHTTP.isTransientNetworkError(error)
    }

    private func sendOnce(path: String, method: String) async throws -> (Data, HTTPURLResponse) {
        // validate() already throws the typed GiteaError.invalidInstance.
        let base = try GiteaCredentials.validate(
            instance: credentials.instance, allowInsecureHTTP: credentials.allowInsecureHTTP)
        guard var components = URLComponents(url: base, resolvingAgainstBaseURL: false) else {
            throw GiteaError.invalidInstance(credentials.instance)
        }
        // Path strings may carry a query ("/tasks?status=waiting"); assigning
        // it to .path would percent-encode the '?'. Split at the first one.
        if let queryStart = path.firstIndex(of: "?") {
            components.path = String(path[..<queryStart])
            components.query = String(path[path.index(after: queryStart)...])
        } else {
            components.path = path
        }
        guard let url = components.url else {
            throw GiteaError.invalidInstance(credentials.instance)
        }
        var req = URLRequest(url: url)
        req.httpMethod = method
        req.setValue("token \(credentials.token)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.setValue("Kinhin/1.0", forHTTPHeaderField: "User-Agent")

        let (data, response) = try await session.data(for: req)
        guard let http = response as? HTTPURLResponse else {
            throw GiteaError.http(0, "non-HTTP response")
        }
        switch http.statusCode {
        case 200...299:
            return (data, http)
        case 401:
            throw GiteaError.unauthorized
        case 403:
            throw GiteaError.forbidden(String(decoding: data.prefix(300), as: UTF8.self))
        case 404:
            throw GiteaError.notFound(path)
        default:
            throw GiteaError.http(http.statusCode, String(decoding: data.prefix(300), as: UTF8.self))
        }
    }
}

// MARK: - Task queue decoding

/// Tolerant decoder for the `/actions/tasks` queue body. Gitea versions wrap
/// the list differently; unknown-shape entries decode with nils rather than
/// failing the batch, so demand is never lost to attribution gaps.
struct TaskQueueWrapper: Decodable {
    let total_count: Int?
    let entries: [TaskEntry]?

    struct TaskEntry: Decodable {
        // Keys that appear across Gitea versions, all optional:
        let id: Int?
        let name: String?
        let title: String?
        let status: String?
        let runner_name: String?
        let repo_full_name: String?
        let repository: String?
        let head_branch: String?
        let head_sha: String?
        // Pipeline-view extras; all optional like the rest.
        let url: String?
        let display_title: String?
        let run_number: Int?
        let run_started_at: String?
        // Nested attribution shape: {"repository":{"full_name":...}}.
        let repositoryObject: RepoObject?

        struct RepoObject: Decodable { let full_name: String? }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            id = try c.decodeIfPresent(Int.self, forKey: .id)
            name = try c.decodeIfPresent(String.self, forKey: .name)
            title = try c.decodeIfPresent(String.self, forKey: .title)
            status = try c.decodeIfPresent(String.self, forKey: .status)
            runner_name = try c.decodeIfPresent(String.self, forKey: .runner_name)
            repo_full_name = try c.decodeIfPresent(String.self, forKey: .repo_full_name)
            // Some versions put a string here, others the {full_name} object
            // below — a type mismatch degrades to nil instead of failing the
            // whole entry.
            // Older/newer Gitea versions disagree on which of the two shapes the
            // `repository` field takes; either being absent is expected, not an error.
            head_branch = try? c.decodeIfPresent(String.self, forKey: .head_branch)
            head_sha = try? c.decodeIfPresent(String.self, forKey: .head_sha)
            url = try? c.decodeIfPresent(String.self, forKey: .url)
            display_title = try? c.decodeIfPresent(String.self, forKey: .display_title)
            run_number = try? c.decodeIfPresent(Int.self, forKey: .run_number)
            run_started_at = try? c.decodeIfPresent(String.self, forKey: .run_started_at)
            repository = try? c.decodeIfPresent(String.self, forKey: .repository)
            repositoryObject = try? c.decodeIfPresent(RepoObject.self, forKey: .repository)
        }

        enum CodingKeys: String, CodingKey {
            case id, name, title, status, runner_name
            case repo_full_name = "repo_full_name"
            case repository
            case head_branch, head_sha
            case url, display_title, run_number, run_started_at
        }
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        total_count = try c.decodeIfPresent(Int.self, forKey: .total_count)
        entries = try c.decodeIfPresent([TaskEntry].self, forKey: .entries)
    }

    enum CodingKeys: String, CodingKey { case total_count, entries }

    var tasks: [GiteaTask] {
        let decoded = (entries ?? []).map { entry -> GiteaTask in
            let repository =
                entry.repo_full_name
                ?? entry.repositoryObject?.full_name
                ?? (entry.repository.flatMap { value in value.contains("/") ? value : nil })
            let name = entry.name ?? entry.title
            return GiteaTask(
                id: entry.id, name: name, repository: repository, status: entry.status,
                runnerName: entry.runner_name, ref: entry.head_branch, sha: entry.head_sha, url: entry.url,
                title: entry.display_title, runNumber: entry.run_number, startedAt: entry.run_started_at)
        }
        // When entries are absent but the instance reports a count (older
        // shapes), fall back to count-only placeholders so demand survives.
        if decoded.isEmpty, let count = total_count, count > 0 {
            return (0..<count).map { _ in GiteaTask(id: nil, name: nil, repository: nil, status: nil) }
        }
        return decoded
    }
}
