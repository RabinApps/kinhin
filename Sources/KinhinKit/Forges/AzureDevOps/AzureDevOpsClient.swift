import Foundation

#if canImport(FoundationNetworking)
    import FoundationNetworking
#endif

/// Azure DevOps REST client for one organization's agent pool: pool lookup
/// (and whether the token can manage it), the pool's agents, deleting one,
/// and the pool's job requests for demand and running attribution.
///
/// Authenticates with a personal access token (HTTP Basic, empty user).
/// Uses api-version 7.0, which Azure DevOps Services and Azure DevOps Server
/// 2022 both serve.
public struct AzureDevOpsClient: Sendable {
    static let apiVersion = "7.0"

    let credentials: AzureDevOpsCredentials
    /// The shared send/retry pipeline (headers, status mapping, backoff).
    let transport: ForgeTransport

    public init(credentials: AzureDevOpsCredentials, session: URLSession? = nil) {
        self.credentials = credentials
        self.transport = ForgeTransport(
            session: ForgeHTTP.session(session), forge: .azuredevops,
            authorization: .basicPassword(credentials.token))
    }

    // MARK: - Pools

    /// The configured pool. Doubles as the permission probe: it fails fast on
    /// a bad token or organization, a missing pool, or a pool the token
    /// cannot manage (registering and deleting agents needs manage rights).
    func resolvePool() async throws -> AzureDevOpsPool {
        let name = credentials.pool
        let managed: [AzureDevOpsPool] = try await list(
            "/_apis/distributedtask/pools",
            [URLQueryItem(name: "poolName", value: name), URLQueryItem(name: "actionFilter", value: "manage")],
            what: "agent pools")
        if let pool = managed.first(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame }) {
            return pool
        }
        let visible: [AzureDevOpsPool] = try await list(
            "/_apis/distributedtask/pools", [URLQueryItem(name: "poolName", value: name)], what: "agent pools")
        guard visible.contains(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame }) else {
            throw AzureDevOpsError.poolNotFound(name)
        }
        throw AzureDevOpsError.cannotManagePool(name)
    }

    /// Pools the token can manage, as `RepoRef`s named by pool, for the
    /// scope pickers.
    public func listPools() async throws -> [RepoRef] {
        let pools: [AzureDevOpsPool] = try await list(
            "/_apis/distributedtask/pools", [URLQueryItem(name: "actionFilter", value: "manage")],
            what: "agent pools")
        return pools.map { RepoRef(fullName: $0.name) }
            .sorted { $0.fullName.localizedCaseInsensitiveCompare($1.fullName) == .orderedAscending }
    }

    // MARK: - Agents

    /// The pool's agents with their assigned request.
    func listAgents(pool: AzureDevOpsPool) async throws -> [AzureDevOpsAgent] {
        try await list(
            "/_apis/distributedtask/pools/\(pool.id)/agents",
            [URLQueryItem(name: "includeAssignedRequest", value: "true")], what: "agents")
    }

    /// Deletes an agent. One that is already gone (404) is what deleting
    /// wanted.
    func deleteAgent(pool: AzureDevOpsPool, id: Int) async throws {
        do {
            _ = try await send("DELETE", "/_apis/distributedtask/pools/\(pool.id)/agents/\(id)")
        } catch ForgeAPIError.notFound {
            Log.info("azuredevops", "agent \(id) is already gone from pool \(pool.name)")
        }
    }

    // MARK: - Jobs

    /// The pool's outstanding job requests (queued and running); finished
    /// ones are left out.
    func jobRequests(pool: AzureDevOpsPool) async throws -> [AzureDevOpsJobRequest] {
        let requests: [AzureDevOpsJobRequest] = try await list(
            "/_apis/distributedtask/pools/\(pool.id)/jobrequests",
            [URLQueryItem(name: "completedRequestCount", value: "0")], what: "job requests")
        return requests.filter { $0.isQueued || $0.isRunning }
    }

    /// The build's timeline (stages, jobs, tasks) and its summary. `project`
    /// is the project id the job request reports.
    func timeline(project: String, buildID: Int) async throws -> AzureDevOpsTimeline {
        let (data, _) = try await send("GET", "/\(project)/_apis/build/builds/\(buildID)/timeline")
        return try decode(data, "build timeline")
    }

    /// One log of a build (a job's or a task's), as text.
    func buildLog(project: String, buildID: Int, logID: Int) async throws -> String {
        let (data, _) = try await send(
            "GET", "/\(project)/_apis/build/builds/\(buildID)/logs/\(logID)", accept: "text/plain")
        return String(decoding: data, as: UTF8.self)
    }

    func build(project: String, buildID: Int) async throws -> AzureDevOpsBuildInfo {
        let (data, _) = try await send("GET", "/\(project)/_apis/build/builds/\(buildID)")
        return try decode(data, "build")
    }

    // MARK: - Plumbing

    private func list<T: Decodable>(_ path: String, _ query: [URLQueryItem], what: String) async throws -> [T] {
        let (data, _) = try await send("GET", path, query)
        let wrapped: AzureDevOpsList<T> = try decode(data, what)
        return wrapped.value
    }

    private func decode<T: Decodable>(_ data: Data, _ what: String) throws -> T {
        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            throw ForgeAPIError.decoding(forge: .azuredevops, what: "\(what): \(error.localizedDescription)")
        }
    }

    func url(_ path: String, _ query: [URLQueryItem] = []) throws -> URL {
        let base = try AzureDevOpsCredentials.validate(
            instance: credentials.instance, allowInsecureHTTP: credentials.allowInsecureHTTP)
        guard var components = URLComponents(url: base, resolvingAgainstBaseURL: false) else {
            throw AzureDevOpsError.invalidInstance(credentials.instance)
        }
        var prefix = components.percentEncodedPath
        while prefix.hasSuffix("/") { prefix.removeLast() }
        components.percentEncodedPath = prefix + path
        components.queryItems = query + [URLQueryItem(name: "api-version", value: Self.apiVersion)]
        guard let url = components.url else { throw AzureDevOpsError.invalidInstance(credentials.instance) }
        return url
    }

    /// Sends with the shared transport: retry on transient failures (network
    /// errors, 429, 5xx) and the common status→error mapping. Azure's own
    /// quirk — a rejected PAT coming back as a sign-in page instead of a 401 —
    /// rides the transport's `classify` hook.
    func send(
        _ method: String, _ path: String, _ query: [URLQueryItem] = [], accept: String = "application/json"
    ) async throws -> (Data, HTTPURLResponse) {
        let target = try url(path, query)
        return try await transport.send(method, target, accept: accept, classify: Self.rejectSignInPage)
    }

    /// A rejected PAT can come back as a sign-in page (203, or a redirect
    /// URLSession followed to an HTML 200) instead of a 401.
    private static func rejectSignInPage(_ http: HTTPURLResponse, _ data: Data) -> ForgeAPIError? {
        let html = http.value(forHTTPHeaderField: "Content-Type")?.lowercased().contains("text/html") == true
        switch http.statusCode {
        case 203:
            return .unauthorized(forge: .azuredevops)
        case 200...299 where html:
            return .unauthorized(forge: .azuredevops)
        default:
            return nil
        }
    }
}
