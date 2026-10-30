import Foundation

#if canImport(FoundationNetworking)
    import FoundationNetworking
#endif

/// Buildkite REST (v2) client covering what the fleet needs: the token's
/// scopes, cluster lookup, the cluster agent token agents register with,
/// the organization's connected agents, and demand from its active builds.
///
/// Everything is organization-wide on Buildkite's API; the cluster narrows
/// it where the API says which cluster a job belongs to.
public struct BuildkiteClient: Sendable {
    let credentials: BuildkiteCredentials
    /// The shared send/retry pipeline (headers, status mapping, backoff).
    let transport: ForgeTransport
    /// Pages read per list (100 items each).
    let maxPages = 20

    public init(credentials: BuildkiteCredentials, session: URLSession? = nil) {
        self.credentials = credentials
        self.transport = ForgeTransport(
            session: ForgeHTTP.session(session), forge: .buildkite, authorization: .bearer(credentials.token))
    }

    private var organizationPath: String {
        "/v2/organizations/\(Self.encodePathSegment(credentials.organization))"
    }

    // MARK: - Token

    /// The scopes of the API access token in use.
    func tokenScopes() async throws -> [String] {
        let (data, _) = try await send("GET", "/v2/access-token")
        struct Info: Decodable { let scopes: [String] }
        let info: Info = try decode(data, "access token")
        return info.scopes
    }

    /// Fails with `insufficientScopes` unless the token has every scope the
    /// fleet uses.
    func verifyScopes() async throws {
        let granted = Set(try await tokenScopes())
        let missing = BuildkiteCredentials.requiredScopes.filter { !granted.contains($0) }
        guard missing.isEmpty else { throw BuildkiteError.insufficientScopes(missing) }
    }

    // MARK: - Clusters

    /// The organization's clusters.
    func clusters() async throws -> [BuildkiteCluster] {
        try await paged("\(organizationPath)/clusters", [], what: "clusters")
    }

    /// The configured cluster, matched by UUID or (case-insensitively) name.
    /// Doubles as the permission probe: it fails fast on a bad token, org or
    /// cluster.
    func resolveCluster() async throws -> BuildkiteCluster {
        guard BuildkiteCredentials.isValidScope(credentials.scope) else {
            throw BuildkiteError.invalidScope(credentials.scope)
        }
        let wanted = credentials.cluster.trimmingCharacters(in: .whitespaces)
        let all = try await clusters()
        if let match = all.first(where: { $0.id == wanted })
            ?? all.first(where: { $0.name.caseInsensitiveCompare(wanted) == .orderedSame })
        {
            return match
        }
        throw BuildkiteError.clusterNotFound(organization: credentials.organization, cluster: wanted)
    }

    /// A cluster's queues (agents must join one that exists).
    func queues(cluster: BuildkiteCluster) async throws -> [BuildkiteQueue] {
        try await paged("\(organizationPath)/clusters/\(cluster.id)/queues", [], what: "queues")
    }

    /// Every organization/cluster pair the token can see, as `org/cluster`,
    /// for the scope pickers.
    public func listScopes() async throws -> [RepoRef] {
        struct Organization: Decodable { let slug: String }
        let organizations: [Organization] = try await paged("/v2/organizations", [], what: "organizations")
        var refs: [RepoRef] = []
        for organization in organizations {
            let client = BuildkiteClient(
                credentials: BuildkiteCredentials(token: credentials.token, scope: "\(organization.slug)/"),
                session: transport.session)
            for cluster in try await client.clusters() {
                refs.append(RepoRef(fullName: "\(organization.slug)/\(cluster.name)"))
            }
        }
        return refs.sorted { $0.fullName.localizedCaseInsensitiveCompare($1.fullName) == .orderedAscending }
    }

    // MARK: - Agent tokens

    /// The cluster's agent tokens (values are not included).
    func agentTokens(cluster: BuildkiteCluster) async throws -> [BuildkiteAgentToken] {
        try await paged("\(organizationPath)/clusters/\(cluster.id)/tokens", [], what: "agent tokens")
    }

    /// Creates an agent token and returns it with its value (the only time
    /// Buildkite reveals it).
    func createAgentToken(cluster: BuildkiteCluster, description: String) async throws -> BuildkiteAgentToken {
        let json = try JSONSerialization.data(withJSONObject: ["description": description], options: [.sortedKeys])
        let (data, _) = try await send("POST", "\(organizationPath)/clusters/\(cluster.id)/tokens", body: json)
        let token: BuildkiteAgentToken = try decode(data, "agent token")
        guard let value = token.token, !value.isEmpty else {
            throw ForgeAPIError.decoding(forge: .buildkite, what: "agent token: the response carried no token value")
        }
        return token
    }

    func deleteAgentToken(cluster: BuildkiteCluster, id: String) async throws {
        _ = try await send("DELETE", "\(organizationPath)/clusters/\(cluster.id)/tokens/\(id)")
    }

    // MARK: - Agents

    /// The organization's connected and stopping agents.
    func listAgents() async throws -> [BuildkiteAgent] {
        try await paged("\(organizationPath)/agents", [], what: "agents")
    }

    /// Stops an agent. One that is no longer connected (400) is already gone,
    /// which is what stopping wanted.
    func stopAgent(id: String) async throws {
        let json = try JSONSerialization.data(withJSONObject: ["force": true], options: [.sortedKeys])
        do {
            _ = try await send("PUT", "\(organizationPath)/agents/\(id)/stop", body: json)
        } catch ForgeAPIError.http(_, 400, _) {
            Log.info("buildkite", "agent \(id) is not connected; nothing to stop")
        }
    }

    // MARK: - Jobs

    /// Script jobs of the organization's active builds, each attributed to
    /// its pipeline. Waiter, block and trigger steps are left out.
    func activeJobs() async throws -> [BuildkiteJob] {
        Self.scriptJobs(of: try await activeBuilds())
    }

    /// The script jobs of `builds`, each attributed to its pipeline.
    static func scriptJobs(of builds: [BuildkiteBuild]) -> [BuildkiteJob] {
        builds.flatMap { build in
            build.jobs.filter { $0.type == "script" }.map { job in
                BuildkiteJob(
                    id: job.id, name: job.name ?? job.id, state: job.state ?? "", agentQueryRules: job.agentQueryRules,
                    pipeline: build.pipeline.slug, agentName: job.agent?.name, clusterID: job.clusterID,
                    buildNumber: build.number,
                    enqueuedAt: PipelineParsing.date(job.runnableAt) ?? PipelineParsing.date(job.createdAt),
                    startedAt: PipelineParsing.date(job.startedAt))
            }
        }
    }

    /// The organization's active builds with all their jobs.
    func activeBuilds() async throws -> [BuildkiteBuild] {
        try await paged(
            "\(organizationPath)/builds",
            ["scheduled", "running", "failing"].map { URLQueryItem(name: "state[]", value: $0) },
            what: "builds")
    }

    /// One build with its jobs, for telemetry's one read of a finished job.
    func build(pipeline: String, number: Int) async throws -> BuildkiteBuild {
        let path = "\(organizationPath)/pipelines/\(Self.encodePathSegment(pipeline))/builds/\(number)"
        let (data, _) = try await send("GET", path)
        return try decode(data, "build")
    }

    /// A job's log so far (needs the token's `read_build_logs` scope).
    func jobLog(pipeline: String, build: Int, job: String) async throws -> String {
        struct Log: Decodable { let content: String? }
        let path =
            "\(organizationPath)/pipelines/\(Self.encodePathSegment(pipeline))/builds/\(build)/jobs/\(Self.encodePathSegment(job))/log"
        let (data, _) = try await send("GET", path)
        let log: Log = try decode(data, "job log")
        return log.content ?? ""
    }

    // MARK: - Plumbing

    /// `a b` → `a%20b`, safe as one URL path segment.
    static func encodePathSegment(_ segment: String) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return segment.addingPercentEncoding(withAllowedCharacters: allowed) ?? segment
    }

    /// Follows the `Link: <…>; rel="next"` header through every page
    /// (bounded by `maxPages`).
    private func paged<T: Decodable>(_ path: String, _ query: [URLQueryItem], what: String) async throws -> [T] {
        var all: [T] = []
        var next: URL? = try url(path, query + [URLQueryItem(name: "per_page", value: "100")])
        var pages = 0
        while let pageURL = next, pages < maxPages {
            let (data, response) = try await send("GET", pageURL)
            let batch: [T] = try decode(data, what)
            all.append(contentsOf: batch)
            pages += 1
            next = batch.isEmpty ? nil : Self.nextPage(response.value(forHTTPHeaderField: "Link"))
            // The token rides on every page request: a `next` link is only
            // followed when it stays on the API host over https.
            if let link = next, !Self.isTrustedPageLink(link) {
                throw BuildkiteError.untrustedPageLink(link.absoluteString)
            }
        }
        return all
    }

    static func isTrustedPageLink(_ url: URL) -> Bool {
        guard let api = URL(string: BuildkiteCredentials.apiBase) else { return false }
        return url.scheme?.lowercased() == "https" && url.host?.lowercased() == api.host?.lowercased()
            && url.user == nil && url.port == nil
    }

    /// The `rel="next"` target of an RFC 8288 `Link` header.
    static func nextPage(_ link: String?) -> URL? {
        guard let link else { return nil }
        for part in link.split(separator: ",") {
            let pieces = part.split(separator: ";").map { $0.trimmingCharacters(in: .whitespaces) }
            guard let target = pieces.first, target.hasPrefix("<"), target.hasSuffix(">"),
                pieces.dropFirst().contains(where: { $0.replacingOccurrences(of: " ", with: "") == #"rel="next""# })
            else { continue }
            return URL(string: String(target.dropFirst().dropLast()))
        }
        return nil
    }

    private func decode<T: Decodable>(_ data: Data, _ what: String) throws -> T {
        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            throw ForgeAPIError.decoding(forge: .buildkite, what: "\(what): \(error.localizedDescription)")
        }
    }

    func url(_ path: String, _ query: [URLQueryItem] = []) throws -> URL {
        guard var components = URLComponents(string: BuildkiteCredentials.apiBase) else {
            throw BuildkiteError.invalidScope(credentials.scope)
        }
        // `path` is already percent-encoded (org and cluster segments).
        components.percentEncodedPath = path
        components.queryItems = query.isEmpty ? nil : query
        guard let url = components.url else { throw BuildkiteError.invalidScope(credentials.scope) }
        return url
    }

    /// Sends with the shared transport: retry on transient failures (network
    /// errors, 429, 5xx) and the common status→error mapping.
    func send(_ method: String, _ path: String, body: Data? = nil) async throws -> (Data, HTTPURLResponse) {
        try await transport.send(method, try url(path), body: body)
    }

    /// A direct-URL send for pagination: the `Link: rel="next"` target is an
    /// absolute URL (checked against the API host before it is followed).
    private func send(_ method: String, _ url: URL, body: Data? = nil) async throws -> (Data, HTTPURLResponse) {
        try await transport.send(method, url, body: body)
    }
}
