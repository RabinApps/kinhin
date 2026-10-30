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
    /// Which server family this account talks to (`.gitea` or `.forgejo`). Gitea and Forgejo share this client but
    /// differ in a few endpoints (queued jobs), so the account's declared forge decides, never the host name.
    public let forge: ForgeID

    public init(
        token: String, scope: String, instance: String, allowInsecureHTTP: Bool = false, forge: ForgeID = .gitea
    ) {
        self.token = token
        self.scope = scope
        self.instance = instance
        self.allowInsecureHTTP = allowInsecureHTTP
        self.forge = forge
    }

    /// The same credentials for `forge`.
    func with(forge: ForgeID) -> GiteaCredentials {
        GiteaCredentials(
            token: token, scope: scope, instance: instance, allowInsecureHTTP: allowInsecureHTTP, forge: forge)
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
    /// The shared send/retry pipeline (headers, status mapping, backoff).
    /// Forgejo is served by this same client, so the messages say Gitea.
    let transport: ForgeTransport

    public init(credentials: GiteaCredentials, session: URLSession? = nil) {
        self.credentials = credentials
        self.transport = ForgeTransport(
            session: ForgeHTTP.session(session), forge: .gitea, authorization: .giteaToken(credentials.token))
    }

    // MARK: - Endpoints

    /// Mint a runner registration token for the scope. The same call doubles
    /// as the permission probe (free, idempotent, registers nothing).
    public func fetchRegistrationToken() async throws -> String {
        let path = "\(credentials.actionsBase)/runners/registration-token"
        let data: Data
        do {
            // GET is what Gitea up to 1.25 and every Forgejo release answer.
            data = try await send(path: path).0
        } catch let error as ForgeAPIError {
            // Gitea 1.26 dropped GET: it answers 404 "Runner not found" and only accepts POST (found by running the
            // e2e suite against 1.26.4). A real 404 (wrong scope, Actions off) fails again on POST with the same
            // error, so falling back never hides it.
            switch error {
            case .notFound, .http(_, 405, _): data = try await send(path: path, method: "POST").0
            default: throw error
            }
        }
        do {
            struct TokenResponse: Decodable { let token: String }
            return try JSONDecoder().decode(TokenResponse.self, from: data).token
        } catch {
            throw ForgeAPIError.decoding(forge: .gitea, what: "registration-token: \(error.localizedDescription)")
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
                throw ForgeAPIError.decoding(forge: .gitea, what: "repos/search: \(error.localizedDescription)")
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
                throw ForgeAPIError.decoding(forge: .gitea, what: "runners: \(error.localizedDescription)")
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
            throw ForgeAPIError.decoding(forge: .gitea, what: "tasks: \(error.localizedDescription)")
        }
    }

    // MARK: - Queued jobs (Gitea 1.25+, Forgejo 11+)

    /// Queued jobs for the scope from the server's own queue endpoint (`/actions/jobs?status=queued` on Gitea
    /// 1.25+, `/actions/runners/jobs?labels=` on Forgejo 11+). Throws when the server has no such endpoint; the
    /// caller falls back to the task queue and decides the floor. `runnerLabels` is the label set a runner of this
    /// fleet would register with: Forgejo returns only the waiting jobs whose `runs-on` fits inside it.
    func queuedJobs(runnerLabels: [String] = []) async throws -> [ForgeJob] {
        // A repo-scoped account's jobs all belong to its one repository, whatever the entry says (Forgejo's
        // names none), so repo routes apply to them.
        let scopeRepository = credentials.scope.contains("/") ? credentials.scope : nil
        return try await jobs(runnerLabels: runnerLabels).map { job in
            ForgeJob(
                name: job.name ?? "job", runnerName: nil, repository: job.repository ?? scopeRepository,
                labels: job.labels, ref: job.ref, sha: job.sha)
        }
    }

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
        // Servers that ignore `status` (Forgejo 11 through 14, Gitea 1.23 to 1.24) answer every task the scope has
        // ever had, finished ones included, so the filter is applied here too. An entry with no status of its own
        // (the older shapes) is kept.
        //
        // A full page may have more behind it, so the walk continues while pages come back full of matches, up to
        // `maxTaskPages`. A page holding anything the filter dropped means the server ignores `status` and has
        // reached history, so the walk stops there instead of paging through finished tasks.
        var matched: [GiteaTask] = []
        var seen = Set<Int>()
        for page in 1...Self.maxTaskPages {
            let batch = try await taskPage(status: status, page: page)
            let mine = batch.tasks.filter { $0.status == nil || $0.status == status }
            // Pages shift while running tasks are touched: a task can show up on two of them.
            matched.append(contentsOf: mine.filter { $0.id.map { seen.insert($0).inserted } ?? true })
            if batch.rawCount < Self.pageSize || mine.count < batch.rawCount { break }
        }
        return matched
    }

    /// Whether any task of the scope is not finished: dispatched to a runner and still going. Used where the server
    /// has no runner list, so the activity of the scope is all there is to tell a busy runner from an idle one.
    ///
    /// The list is newest-updated first (a running task is touched by its runner every few seconds, so it stays near
    /// the top however much history the scope has), so the walk stops at the first finished-only page that is not
    /// full, and gives up on history after `maxPages`. A task whose status the server leaves out counts as active:
    /// a leaked instance is the cheaper mistake.
    func activeTaskCount(maxPages: Int = 4) async throws -> Int {
        var active = 0
        for page in 1...max(1, maxPages) {
            let batch = try await taskPage(status: "running", page: page)
            active += batch.tasks.filter { !Self.finishedStatuses.contains($0.status ?? "") }.count
            if active > 0 || batch.rawCount < Self.pageSize { break }
        }
        return active
    }

    /// Terminal task states Gitea and Forgejo report (`unknown` is a task that never ran).
    private static let finishedStatuses: Set<String> = ["success", "failure", "cancelled", "skipped", "unknown"]
    private static let pageSize = 50
    private static let maxTaskPages = 4

    /// One task by id, for telemetry. The task list is newest-updated first and has no by-id route, so the walk
    /// reads the unfiltered list (finished tasks included) for at most two pages, which holds a task that ended a
    /// moment ago. Nil when it is not there.
    func task(id: Int) async throws -> GiteaTask? {
        for page in 1...2 {
            let batch = try await taskPage(status: nil, page: page)
            if let found = batch.tasks.first(where: { $0.id == id }) { return found }
            if batch.rawCount < Self.pageSize { break }
        }
        return nil
    }

    private func taskPage(status: String?, page: Int) async throws -> (tasks: [GiteaTask], rawCount: Int) {
        let filter = status.map { "status=\($0)&" } ?? ""
        let (data, _) = try await send(
            path: "\(credentials.actionsBase)/tasks?\(filter)page=\(page)&limit=\(Self.pageSize)")
        do {
            let wrapper = try JSONDecoder().decode(TaskQueueWrapper.self, from: data)
            return (wrapper.tasks, wrapper.entries?.count ?? 0)
        } catch {
            throw ForgeAPIError.decoding(forge: .gitea, what: "tasks: \(error.localizedDescription)")
        }
    }

    // MARK: - Jobs endpoint (Gitea 1.25+, Forgejo 11+)

    /// Waiting jobs of the scope. Both shapes were probed live (Gitea 1.25.5 and 1.26.4, Forgejo 11):
    ///
    /// - Gitea: `GET …/actions/jobs?status=queued` returns `{"jobs":[{"name","labels",…}],"total_count"}`. The
    ///   status of a job nobody has picked up is `queued`; `waiting` matches nothing.
    /// - Forgejo: `GET …/actions/runners/jobs?labels=a,b` returns a bare array (or `null`) of
    ///   `{"id","name","runs_on":[…],"status":"waiting"}`, only the jobs whose `runs_on` fits inside `labels`. An
    ///   empty `labels` matches nothing, and the entries name no repository.
    func jobs(runnerLabels: [String]) async throws -> [GiteaJob] {
        if credentials.forge == .forgejo {
            let labels = Self.runnerLabelQuery(runnerLabels)
            guard !labels.isEmpty else { return [] }
            let encoded = labels.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? labels
            let (data, _) = try await send(path: "\(credentials.actionsBase)/runners/jobs?labels=\(encoded)")
            do {
                // `null` (nothing waiting) decodes as an empty list.
                let list = try JSONDecoder().decode([GiteaJob]?.self, from: data) ?? []
                return list.filter { ($0.status ?? "waiting") == "waiting" }
            } catch {
                throw ForgeAPIError.decoding(forge: .forgejo, what: "runner jobs: \(error.localizedDescription)")
            }
        }
        let (data, _) = try await send(path: "\(credentials.actionsBase)/jobs?status=queued&page=1&limit=50")
        do {
            return try JSONDecoder().decode(JobsWrapper.self, from: data).jobs
        } catch {
            throw ForgeAPIError.decoding(forge: .gitea, what: "jobs: \(error.localizedDescription)")
        }
    }

    /// The labels a runner of this fleet answers to, as a `runs-on` name list: the account's labels without
    /// Gitea's `:host` / `:docker://…` scheme, plus kinhin's exclusive pool markers (a Docker pool registers with
    /// `kinhin-docker`, so a job asking for it must fit).
    static func runnerLabelQuery(_ labels: [String]) -> String {
        var names: [String] = []
        for label in labels + ["kinhin-container", "kinhin-docker", "kinhin-host"] {
            let name = label.split(separator: ":", maxSplits: 1).first.map(String.init) ?? label
            if !name.isEmpty, !names.contains(name) { names.append(name) }
        }
        return names.joined(separator: ",")
    }

    // MARK: - Plumbing

    /// Sends with the shared transport: retry on transient failures (network
    /// errors, 429, 5xx), matching the GitHub client's resilience to blips.
    func send(path: String, method: String = "GET") async throws -> (Data, HTTPURLResponse) {
        try await transport.send(method, try url(path))
    }

    /// The request URL for an endpoint path. `validate()` already throws the
    /// typed `GiteaError.invalidInstance`.
    func url(_ path: String) throws -> URL {
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
        return url
    }
}

// MARK: - Task queue decoding

/// Tolerant decoder for the `/actions/tasks` queue body. Gitea versions wrap
/// the list differently; unknown-shape entries decode with nils rather than
/// failing the batch, so demand is never lost to attribution gaps.
struct TaskQueueWrapper: Decodable {
    let total_count: Int?
    /// `entries` (the shape this decoder was written against) or `workflow_runs` (what Forgejo 11 and the
    /// published specs use; found live on Forgejo 11, which answers no `entries` at all).
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
        let created_at: String?
        let updated_at: String?
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
            // Leniency policy: these fields are display-only and their types
            // differ across Gitea/Forgejo versions (`repository` is a string on
            // some, a {full_name} object on others), so a type mismatch
            // degrades that one field to nil instead of dropping the whole run.
            head_branch = try? c.decodeIfPresent(String.self, forKey: .head_branch)  // lenient: see above
            head_sha = try? c.decodeIfPresent(String.self, forKey: .head_sha)  // lenient: see above
            url = try? c.decodeIfPresent(String.self, forKey: .url)  // lenient: see above
            display_title = try? c.decodeIfPresent(String.self, forKey: .display_title)  // lenient: see above
            run_number = try? c.decodeIfPresent(Int.self, forKey: .run_number)  // lenient: see above
            run_started_at = try? c.decodeIfPresent(String.self, forKey: .run_started_at)  // lenient: see above
            created_at = try? c.decodeIfPresent(String.self, forKey: .created_at)  // lenient: see above
            updated_at = try? c.decodeIfPresent(String.self, forKey: .updated_at)  // lenient: see above
            repository = try? c.decodeIfPresent(String.self, forKey: .repository)  // lenient: see above
            repositoryObject = try? c.decodeIfPresent(RepoObject.self, forKey: .repository)  // lenient: see above
        }

        enum CodingKeys: String, CodingKey {
            case id, name, title, status, runner_name
            case repo_full_name = "repo_full_name"
            case repository
            case head_branch, head_sha
            case url, display_title, run_number, run_started_at, created_at, updated_at
        }
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        total_count = try c.decodeIfPresent(Int.self, forKey: .total_count)
        let named = try c.decodeIfPresent([TaskEntry].self, forKey: .entries)
        entries = try named ?? c.decodeIfPresent([TaskEntry].self, forKey: .workflow_runs)
    }

    enum CodingKeys: String, CodingKey { case total_count, entries, workflow_runs }

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
                title: entry.display_title, runNumber: entry.run_number, startedAt: entry.run_started_at,
                createdAt: entry.created_at, updatedAt: entry.updated_at)
        }
        // When entries are absent but the instance reports a count (older
        // shapes), fall back to count-only placeholders so demand survives.
        if decoded.isEmpty, let count = total_count, count > 0 {
            return (0..<count).map { _ in GiteaTask(id: nil, name: nil, repository: nil, status: nil) }
        }
        return decoded
    }
}

// MARK: - Jobs endpoint models (Gitea 1.25+, Forgejo 11+)

/// One queued job from the server's own queue endpoint. The fields below are
/// what the published specs and live probes expose; unknowns decode as nil.
struct GiteaJob: Decodable {
    let id: Int?
    let name: String?
    let status: String?
    /// The job's repository (`owner/name`). Neither queue endpoint names it outright (probed live: a Gitea 1.26
    /// job carries only `url`, `…/repos/<owner>/<name>/actions/jobs/<id>`; a Forgejo 11 entry only `repo_id`), so
    /// it is read from a `repository` field when a server sends one, else from that `url`. Nil when neither says.
    let repository: String?
    /// Branch and commit: `head_branch` / `head_sha` on Gitea 1.25+ (`ref` / `sha` on older shapes).
    let ref: String?
    let sha: String?
    /// The job's `runs-on` labels: `labels` on Gitea, `runs_on` on Forgejo. Routing opts a job into a pool by them.
    let labels: [String]?

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(Int.self, forKey: .id)
        name = try c.decodeIfPresent(String.self, forKey: .name)
        status = try c.decodeIfPresent(String.self, forKey: .status)
        // A string on some shapes, an object with `full_name` on others: each
        // attempt is lenient (a mismatch is nil), and the job URL is the fallback.
        let asString = try? c.decodeIfPresent(String.self, forKey: .repository)
        let asObject = try? c.decodeIfPresent(RepositoryRef.self, forKey: .repository)  // lenient: see above
        let named = (asString ?? nil) ?? (asObject ?? nil)?.fullName
        let jobURL = try c.decodeIfPresent(String.self, forKey: .url)
        repository = named ?? Self.repository(fromJobURL: jobURL)
        ref = try c.decodeIfPresent(String.self, forKey: .ref) ?? c.decodeIfPresent(String.self, forKey: .headBranch)
        sha = try c.decodeIfPresent(String.self, forKey: .sha) ?? c.decodeIfPresent(String.self, forKey: .headSHA)
        labels =
            try c.decodeIfPresent([String].self, forKey: .labels)
            ?? c.decodeIfPresent([String].self, forKey: .runsOn)
    }

    /// `owner/name` from a job's API URL (`…/api/v1/repos/<owner>/<name>/actions/jobs/<id>`), nil for any other shape.
    static func repository(fromJobURL url: String?) -> String? {
        guard let url, let path = URL(string: url)?.path else { return nil }
        let parts = path.split(separator: "/").map(String.init)
        guard let repos = parts.firstIndex(of: "repos"), parts.count > repos + 3, parts[repos + 3] == "actions"
        else { return nil }
        return "\(parts[repos + 1])/\(parts[repos + 2])"
    }

    private struct RepositoryRef: Decodable {
        let fullName: String?
        enum CodingKeys: String, CodingKey { case fullName = "full_name" }
    }

    enum CodingKeys: String, CodingKey {
        case id, name, status, repository, ref, sha, labels, url
        case runsOn = "runs_on"
        case headBranch = "head_branch"
        case headSHA = "head_sha"
    }
}

struct JobsWrapper: Decodable {
    /// Gitea 1.25+ uses `total_count`; Forgejo's runner-jobs endpoint uses
    /// `count`. Tolerate either.
    let total_count: Int?
    let count: Int?
    let jobs: [GiteaJob]

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        total_count = try c.decodeIfPresent(Int.self, forKey: .total_count)
        count = try c.decodeIfPresent(Int.self, forKey: .count)
        jobs = try c.decodeIfPresent([GiteaJob].self, forKey: .jobs) ?? []
    }

    enum CodingKeys: String, CodingKey { case total_count, count, jobs }
}
