import Foundation

#if canImport(FoundationNetworking)
    import FoundationNetworking
#endif

/// Bitbucket Cloud REST (2.0) client covering what the fleet needs: the
/// token's workspace, self-hosted runner CRUD (workspace- or repo-scoped,
/// each runner created with its own OAuth client credentials), and demand
/// from the active pipelines' steps.
///
/// Authenticates with a workspace or repository access token (Bearer). The
/// runner endpoints are the recently published public ones (BCLOUD-21309).
public struct BitbucketClient: Sendable {
    let credentials: BitbucketCredentials
    let session: URLSession
    /// Pages read per list (100 items each).
    let maxPages = 20

    public init(credentials: BitbucketCredentials, session: URLSession? = nil) {
        self.credentials = credentials
        self.session = ForgeHTTP.session(session)
    }

    // MARK: - Scope

    /// The configured scope's workspace, as `RepoRef`s named `workspace` /
    /// `workspace/repo` — workspace scopes list the repos the token can see,
    /// repository scopes return just the one. For the scope pickers.
    public func listScopes() async throws -> [RepoRef] {
        let scope = BitbucketScope(credentials: credentials)
        guard case .workspace = scope else {
            return [RepoRef(fullName: scope.description)]
        }
        let repos: [Repo] = try await paged(
            "\(scope.pipelinesPath)", [URLQueryItem(name: "role", value: "contributor")], what: "repositories")
        return repos.map { RepoRef(fullName: $0.fullName) }
            .sorted { $0.fullName.localizedCaseInsensitiveCompare($1.fullName) == .orderedAscending }
    }

    private struct Repo: Decodable, Sendable {
        let fullName: String

        enum CodingKeys: String, CodingKey {
            case fullName = "full_name"
        }
    }

    /// Verifies the scope exists and the token can see it: a workspace
    /// lookup, or the repository's own endpoint. Doubles as the permission
    /// probe at forge-build time.
    func verifyScope() async throws {
        let scope = BitbucketScope(credentials: credentials)
        let path: String
        let what: String
        switch scope {
        case .workspace(let name):
            path = "/2.0/workspaces/\(name)"
            what = "workspace \(name)"
        case .repository(let workspace, let slug):
            path = "/2.0/repositories/\(workspace)/\(slug)"
            what = "repository \(scope.description)"
        }
        do {
            _ = try await send("GET", path)
        } catch BitbucketError.notFound {
            throw BitbucketError.scopeNotFound(what)
        }
    }

    // MARK: - Runners

    /// The scope's self-hosted runners.
    func listRunners(scope: BitbucketScope) async throws -> [BitbucketRunner] {
        try await paged("\(scope.runnerPath)", [], what: "runners")
    }

    /// Creates a runner and returns it with the OAuth client credentials
    /// agents authenticate with (the secret is only ever in this response).
    func createRunner(scope: BitbucketScope, name: String, labels: [String]) async throws -> BitbucketRunner {
        let body = try JSONSerialization.data(
            withJSONObject: ["name": name, "labels": labels], options: [.sortedKeys])
        let (data, _) = try await send("POST", scope.runnerPath, body: body)
        let runner: BitbucketRunner = try decode(data, "created runner")
        guard let secret = runner.oauthClient?.secret, !secret.isEmpty else {
            throw BitbucketError.missingOAuthClientSecret(name)
        }
        return runner
    }

    /// Deletes a runner. One that is already gone (404) is what deleting
    /// wanted.
    func deleteRunner(scope: BitbucketScope, uuid: String) async throws {
        do {
            _ = try await send("DELETE", "\(scope.runnerPath)/\(uuid)")
        } catch BitbucketError.notFound {
            Log.info("bitbucket", "runner \(uuid) is already gone")
        }
    }

    // MARK: - Jobs

    /// Steps of the scope's active pipelines, each attributed to its
    /// repository. Only pipelines still pending or in progress are followed
    /// to their steps (they lead the newest-first list, so one page per repo
    /// suffices). Workspace scopes poll the recently active repos the caller
    /// passes; repository scopes poll their one repo.
    func activeJobs(scope: BitbucketScope, repos: [String]) async throws -> [BitbucketJob] {
        let targets: [(repo: String, path: String)]
        switch scope {
        case .workspace:
            targets = repos.map { ($0, "/2.0/repositories/\($0)/pipelines/") }
        case .repository(let workspace, let slug):
            targets = [("\(workspace)/\(slug)", "/2.0/repositories/\(workspace)/\(slug)/pipelines/")]
        }
        var steps: [BitbucketStep] = []
        for target in targets {
            let pipelines: [BitbucketPipeline] = try await paged(
                target.path, [URLQueryItem(name: "sort", value: "-created_on")], what: "pipelines", pageLimit: 1)
            for pipeline in pipelines where pipeline.stateName == "PENDING" || pipeline.stateName == "IN_PROGRESS" {
                let pipelineSteps: [BitbucketStep] = try await paged(
                    "\(target.path)\(pipeline.uuid)/steps", [], what: "steps")
                steps.append(
                    contentsOf: pipelineSteps.map { step in
                        var step = step
                        step.repository = target.repo
                        return step
                    })
            }
        }
        return steps.map(BitbucketJob.init)
    }

    /// The workspace's repositories by last activity (newest first), for the
    /// "poll recently active repos only" demand strategy: one page (100)
    /// bounds the read.
    func activeRepositories(scope: BitbucketScope) async throws -> [String] {
        let repos: [BitbucketRepoRef] = try await paged(
            "\(scope.pipelinesPath)", [URLQueryItem(name: "sort", value: "-updated_on")],
            what: "repositories", pageLimit: 1)
        return repos.map(\.fullName)
    }

    // MARK: - UUIDs

    /// The workspace's UUID, as the agent start command's `--accountUuid`
    /// expects it (`{…}` braces included).
    func workspaceUUID(scope: BitbucketScope) async throws -> String {
        let (data, _) = try await send("GET", scope.workspacePath)
        struct Workspace: Decodable { let uuid: String }
        let workspace: Workspace = try decode(data, "workspace")
        return workspace.uuid
    }

    /// The repository's UUID (for `--repositoryUuid`), nil on workspace
    /// scopes.
    func repositoryUUID(scope: BitbucketScope) async throws -> String? {
        guard let path = scope.repositoryPath else { return nil }
        let (data, _) = try await send("GET", path)
        struct Repo: Decodable { let uuid: String }
        let repo: Repo = try decode(data, "repository")
        return repo.uuid
    }

    // MARK: - Plumbing

    /// Follows the `next` page links through every page (bounded by
    /// `maxPages`).
    private func paged<T: Decodable>(
        _ path: String, _ query: [URLQueryItem], what: String, pageLimit: Int? = nil
    ) async throws -> [T] {
        var all: [T] = []
        var next: URL? = try url(path, query + [URLQueryItem(name: "pagelen", value: "100")])
        var pages = 0
        while let pageURL = next, pages < (pageLimit ?? maxPages) {
            // `next` links are absolute URLs already.
            let (data, _) = try await send("GET", pageURL.absoluteString)
            let batch: Page<T> = try decode(data, what)
            all.append(contentsOf: batch.values)
            pages += 1
            next = batch.values.isEmpty ? nil : batch.next
        }
        return all
    }

    private struct Page<T: Decodable>: Decodable {
        let values: [T]
        let next: URL?
    }

    private func decode<T: Decodable>(_ data: Data, _ what: String) throws -> T {
        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            throw BitbucketError.decoding("\(what): \(error.localizedDescription)")
        }
    }

    static func isTrustedPageLink(_ url: URL) -> Bool {
        guard let api = URL(string: BitbucketCredentials.apiBase) else { return false }
        return url.scheme?.lowercased() == "https" && url.host?.lowercased() == api.host?.lowercased()
            && url.user == nil && url.port == nil
    }

    func url(_ path: String, _ query: [URLQueryItem] = []) throws -> URL {
        // A `path` that already starts with the API base (a `next` page link)
        // is used as is.
        if path.contains("://") {
            // Compare parsed hosts: a string prefix also matches
            // `https://api.bitbucket.org.evil.example`.
            guard let absolute = URLComponents(string: path), let absoluteURL = absolute.url,
                Self.isTrustedPageLink(absoluteURL)
            else {
                throw BitbucketError.untrustedPageLink(path)
            }
            return absoluteURL
        }
        guard var components = URLComponents(string: BitbucketCredentials.apiBase) else {
            throw BitbucketError.invalidScope(credentials.scope)
        }
        // Runner and pipeline UUIDs carry `{}` braces; the unencoded `path`
        // setter percent-encodes them (and anything else) as required.
        components.path = path
        components.queryItems = query.isEmpty ? nil : query
        guard let url = components.url else { throw BitbucketError.invalidScope(credentials.scope) }
        return url
    }

    /// Sends with retry on transient failures (network errors, 429, 5xx).
    func send(_ method: String, _ path: String, body: Data? = nil) async throws -> (Data, HTTPURLResponse) {
        try await send(method, try url(path), body: body)
    }

    private func send(_ method: String, _ url: URL, body: Data?) async throws -> (Data, HTTPURLResponse) {
        try await withTransientRetry(isTransient: Self.isTransient) {
            try await sendOnce(method, url, body: body)
        }
    }

    static func isTransient(_ error: Error) -> Bool {
        if case .http(let code, _) = error as? BitbucketError { return ForgeHTTP.isTransientStatus(code) }
        return ForgeHTTP.isTransientNetworkError(error)
    }

    private func sendOnce(_ method: String, _ url: URL, body: Data?) async throws -> (Data, HTTPURLResponse) {
        var req = URLRequest(url: url)
        req.httpMethod = method
        req.setValue("Bearer \(credentials.token)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.setValue("Kinhin/1.0", forHTTPHeaderField: "User-Agent")
        if let body {
            req.httpBody = body
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        let (data, response) = try await session.data(for: req)
        guard let http = response as? HTTPURLResponse else {
            throw BitbucketError.http(0, "non-HTTP response")
        }
        switch http.statusCode {
        case 200...299:
            return (data, http)
        case 401:
            throw BitbucketError.unauthorized
        case 403:
            throw BitbucketError.forbidden(String(decoding: data.prefix(300), as: UTF8.self))
        case 404:
            throw BitbucketError.notFound(url.path)
        default:
            throw BitbucketError.http(http.statusCode, String(decoding: data.prefix(300), as: UTF8.self))
        }
    }
}
