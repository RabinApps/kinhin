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
    let session: URLSession

    public init(credentials: AzureDevOpsCredentials, session: URLSession? = nil) {
        self.credentials = credentials
        self.session = ForgeHTTP.session(session)
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
        } catch AzureDevOpsError.notFound {
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
            throw AzureDevOpsError.decoding("\(what): \(error.localizedDescription)")
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

    /// Sends with retry on transient failures (network errors, 429, 5xx).
    func send(_ method: String, _ path: String, _ query: [URLQueryItem] = []) async throws
        -> (Data, HTTPURLResponse)
    {
        let target = try url(path, query)
        return try await withTransientRetry(isTransient: Self.isTransient) {
            try await sendOnce(method, target)
        }
    }

    static func isTransient(_ error: Error) -> Bool {
        if case .http(let code, _) = error as? AzureDevOpsError { return ForgeHTTP.isTransientStatus(code) }
        return ForgeHTTP.isTransientNetworkError(error)
    }

    private func sendOnce(_ method: String, _ url: URL) async throws -> (Data, HTTPURLResponse) {
        var req = URLRequest(url: url)
        req.httpMethod = method
        let basic = Data(":\(credentials.token)".utf8).base64EncodedString()
        req.setValue("Basic \(basic)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.setValue("Kinhin/1.0", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await session.data(for: req)
        guard let http = response as? HTTPURLResponse else {
            throw AzureDevOpsError.http(0, "non-HTTP response")
        }
        // A rejected PAT can come back as a sign-in page (203, or a redirect
        // URLSession followed to an HTML 200) instead of a 401.
        let html = http.value(forHTTPHeaderField: "Content-Type")?.lowercased().contains("text/html") == true
        switch http.statusCode {
        case 203:
            throw AzureDevOpsError.unauthorized
        case 200...299 where html:
            throw AzureDevOpsError.unauthorized
        case 200...299:
            return (data, http)
        case 401:
            throw AzureDevOpsError.unauthorized
        case 403:
            throw AzureDevOpsError.forbidden(String(decoding: data.prefix(300), as: UTF8.self))
        case 404:
            throw AzureDevOpsError.notFound(url.path)
        default:
            throw AzureDevOpsError.http(http.statusCode, String(decoding: data.prefix(300), as: UTF8.self))
        }
    }
}
