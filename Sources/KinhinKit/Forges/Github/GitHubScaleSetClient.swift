import Foundation

// MARK: - Scale-set API client

/// GitHub's Runner Scale Set message API client for one GitHub account.
public protocol GitHubScaleSetServing: Sendable {
    func exchangeRegistrationToken(registrationToken: String) async throws -> GitHubScaleSetRegistrationToken
    func ensureScaleSet(name: String, labels: [String], runnerGroup: String?) async throws -> GitHubScaleSet
    func patchScaleSet(id: Int, labels: [String]) async throws
    func createSession(scaleSetId: Int, ownerName: String) async throws -> GitHubScaleSetSession
    func refreshSession(scaleSetId: Int, sessionId: String) async throws -> GitHubScaleSetSession
    func deleteSession(scaleSetId: Int, sessionId: String) async throws
    func pollMessages(session: GitHubScaleSetSession, lastMessageId: String?, maxCapacity: Int) async throws
        -> [GitHubScaleSetMessage]
    func ackMessage(session: GitHubScaleSetSession, messageId: String) async throws
    func generateJitConfig(scaleSetId: Int, name: String, workFolder: String) async throws -> GitHubScaleSetJitConfig
    func scaleSetStatistics(scaleSetId: Int) async throws -> GitHubScaleSetStatistics
}

public enum GitHubScaleSetClientError: LocalizedError, Sendable {
    case messageQueueTokenExpired

    public var errorDescription: String? {
        switch self {
        case .messageQueueTokenExpired: "scale-set message queue token expired"
        }
    }
}

public enum GitHubScaleSetError: LocalizedError, Sendable {
    case adminTokenExchangeFailed(original: String)
    case scaleSetNotFound(name: String)
    case scaleSetUnavailable(id: Int, reason: String)
    case sessionFailure(id: Int?, message: String)
    case noSession
    case messagePollFailed(original: String)
    case jitConfigFailed(original: String)
    case runnerNotFound(name: String)

    public var errorDescription: String? {
        switch self {
        case .adminTokenExchangeFailed(let original): return "scale-set admin token exchange failed: \(original)"
        case .scaleSetNotFound(let name): return "scale set '\(name)' was not found"
        case .scaleSetUnavailable(let id, let reason): return "scale set \(id) is unavailable: \(reason)"
        case .sessionFailure(let id, let message):
            return "scale-set session\(id.map { " \($0)" } ?? "") failed: \(message)"
        case .noSession: return "no scale-set session is active"
        case .messagePollFailed(let original): return "scale-set message poll failed: \(original)"
        case .jitConfigFailed(let original): return "JIT config generation failed: \(original)"
        case .runnerNotFound(let name): return "runner '\(name)' was not found"
        }
    }
}

public struct GitHubActionsRunner: Sendable, Equatable, Decodable {
    public let id: Int
    public let name: String
    public let busy: Bool
    public let isIdle: Bool

    enum CodingKeys: String, CodingKey {
        case id
        case name
        case busy
        case isIdle
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(Int.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        busy = try container.decode(Bool.self, forKey: .busy)
        isIdle = try container.decode(Bool.self, forKey: .isIdle)
    }
}

// MARK: - Concrete client

public struct GitHubScaleSetClient: GitHubScaleSetServing {
    public let credentials: GitHubCredentials
    public let session: URLSession
    private let adminJwtProvider: @Sendable () async throws -> String
    private let actionsServiceURL: @Sendable () -> URL?

    public init(
        credentials: GitHubCredentials,
        session: URLSession? = nil,
        adminJwtProvider: @escaping @Sendable () async throws -> String = {
            throw ScaleSetError.adminTokenFailure(reason: "admin JWT provider is not configured")
        },
        actionsServiceURL: @escaping @Sendable () -> URL? = { nil }
    ) {
        self.credentials = credentials
        self.session = ForgeHTTP.session(session)
        self.adminJwtProvider = adminJwtProvider
        self.actionsServiceURL = actionsServiceURL
    }

    private func adminRequest(method: String, path: String, body: Data? = nil) async throws -> URLRequest {
        let jwt = try await adminJwtProvider()
        guard let serviceURL = actionsServiceURL() else {
            throw ScaleSetError.adminTokenFailure(reason: "Actions service URL is unavailable")
        }
        var request = try request(method: method, path: path, body: body, headers: [:], baseURL: serviceURL)
        request.setValue("Bearer \(jwt)", forHTTPHeaderField: "Authorization")
        return request
    }

    // MARK: - Plumbing

    func request(
        method: String, path: String, body: Data? = nil, headers: [String: String] = [:]
    ) throws -> URLRequest {
        try request(method: method, path: path, body: body, headers: headers, baseURL: nil)
    }

    private func restBaseURL(for instance: String?) -> URL {
        guard let instance, let url = URL(string: instance), let host = url.host else {
            return URL(string: "https://api.github.com")!
        }
        if host.hasSuffix(".ghe.com") {
            return URL(string: "https://api.\(host)")!
        }
        return URL(string: "https://\(host)/api/v3")!
    }

    private func request(
        method: String, path: String, body: Data?, headers: [String: String] = [:], baseURL: URL?
    ) throws -> URLRequest {
        let base =
            credentials.isEnterprise ? restBaseURL(for: credentials.instance) : URL(string: "https://api.github.com")!
        guard var components = URLComponents(string: base.absoluteString + path) else {
            throw GitHubError.http(0, "invalid request path \(path)")
        }
        let isAdminRequest = path.hasPrefix("/_apis/")
        if isAdminRequest, let actionsURL = baseURL {
            guard let actionsComponents = URLComponents(url: actionsURL, resolvingAgainstBaseURL: false),
                let scheme = actionsComponents.scheme, let host = actionsComponents.host,
                scheme == "https"
            else {
                throw GitHubError.http(0, "invalid Actions service URL")
            }
            // github.com: the exchanged Actions URL is the endpoint host — the
            // runtime API lives there, not on api.github.com. Enterprise: admin
            // calls stay on the instance's API host (data residency) and adopt
            // only the exchanged URL's path prefix.
            let authority = credentials.isEnterprise ? restBaseURL(for: credentials.instance) : actionsURL
            guard let authorityHost = authority.host else {
                throw GitHubError.http(0, "invalid Actions service URL")
            }
            components.scheme = authority.scheme ?? scheme
            components.host = authorityHost
            components.port = authority.port
            let basePath = actionsComponents.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            // The endpoint arrives as one string (path + query); only the
            // path half is composed here — `components` already parsed the
            // query. The exchanged URL may also already end in
            // `_apis/runtime`; appending the full endpoint after it would
            // double the segment.
            var endpointPath = path.split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false)[0]
                .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            if basePath.hasSuffix("_apis/runtime"), endpointPath.hasPrefix("_apis/runtime") {
                endpointPath = String(endpointPath.dropFirst("_apis/runtime".count))
                    .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            }
            components.path = "/" + [basePath, endpointPath].filter { !$0.isEmpty }.joined(separator: "/")
            components.queryItems = (actionsComponents.queryItems ?? []) + (components.queryItems ?? [])
        }
        if isAdminRequest {
            var queryItems = components.queryItems ?? []
            if !queryItems.contains(where: { $0.name == "api-version" }) {
                queryItems.append(URLQueryItem(name: "api-version", value: "6.0-preview"))
            }
            components.queryItems = queryItems
        }
        guard let url = components.url else {
            throw GitHubError.http(0, "invalid request path \(path)")
        }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.httpBody = body
        for (key, value) in headers { request.setValue(value, forHTTPHeaderField: key) }
        request.setValue(
            isAdminRequest ? "application/json; api-version=6.0-preview" : "application/vnd.github+json",
            forHTTPHeaderField: "Accept")
        request.setValue("Kinhin/1.0", forHTTPHeaderField: "User-Agent")
        request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        return request
    }

    func request<T: Encodable>(
        method: String, path: String, body: T, headers: [String: String] = [:]
    ) throws -> URLRequest {
        try request(method: method, path: path, body: JSONEncoder().encode(body), headers: headers)
    }

    func send(_ request: URLRequest, retries: Int = 3) async throws -> (Data, HTTPURLResponse) {
        var attempt = 0
        var lastError: Error = GitHubError.http(0, "no attempt made")
        while attempt <= retries {
            if attempt > 0 {
                try await Task.sleep(for: .seconds(min(8.0, pow(2, Double(attempt)))))
            }
            attempt += 1
            do {
                let (data, response) = try await self.session.data(for: request)
                guard let http = response as? HTTPURLResponse else {
                    lastError = GitHubError.http(0, "non-HTTP response")
                    continue
                }
                switch http.statusCode {
                case 200...299: return (data, http)
                case 401: throw GitHubError.unauthorized
                case 403:
                    if http.value(forHTTPHeaderField: "X-RateLimit-Remaining") == "0",
                        let reset = http.value(forHTTPHeaderField: "X-RateLimit-Reset").flatMap(TimeInterval.init)
                    {
                        throw GitHubError.rateLimited(resetAt: Date(timeIntervalSince1970: reset))
                    }
                    lastError = GitHubError.forbidden(String(decoding: data.prefix(500), as: UTF8.self))
                    continue
                case 404: throw GitHubError.notFound(request.url?.path ?? "resource")
                case 429, 500...599:
                    lastError = GitHubError.http(http.statusCode, String(decoding: data.prefix(500), as: UTF8.self))
                    continue
                default: throw GitHubError.http(http.statusCode, String(decoding: data.prefix(500), as: UTF8.self))
                }
            } catch let error as GitHubError {
                if case .forbidden = error { lastError = error; continue }
                if case .http(let code, _) = error, code == 429 || code >= 500 { lastError = error; continue }
                if case .http(0, _) = error { lastError = error; continue }
                throw error
            } catch is CancellationError {
                throw CancellationError()
            } catch let error as URLError where error.code == .cancelled {
                throw CancellationError()
            } catch let error where ForgeHTTP.isTransientNetworkError(error) {
                lastError = GitHubError.http(0, error.localizedDescription)
            }
        }
        throw lastError
    }

    // MARK: - Admin token exchange

    public func exchangeRegistrationToken(registrationToken: String) async throws -> GitHubScaleSetRegistrationToken {
        struct RegistrationExchange: Encodable {
            let url: String
            let runner_event = "register"
        }
        var request = try request(method: "POST", path: "/actions/runner-registration")
        request.httpBody = try JSONEncoder().encode(RegistrationExchange(url: credentials.configureURL))
        request.setValue("RemoteAuth \(registrationToken)", forHTTPHeaderField: "Authorization")
        let (data, _) = try await send(request)
        return try JSONDecoder.scaleSetRegistrationDate.decode(GitHubScaleSetRegistrationToken.self, from: data)
    }

    // MARK: - Scale set lifecycle

    struct ScaleSetCreate: Encodable {
        let name: String
        let labels: [ScaleSetLabel]
        let runnerGroupId: Int

        init(name: String, labels: [String], runnerGroupId: Int) {
            self.name = name
            self.labels = labels.map { ScaleSetLabel(name: $0, type: "System") }
            self.runnerGroupId = runnerGroupId
        }
    }
    struct ScaleSetPatch: Encodable {
        let labels: [ScaleSetLabel]

        init(labels: [String]) {
            self.labels = labels.map { ScaleSetLabel(name: $0, type: "System") }
        }
    }
    struct ScaleSetLabel: Encodable { let name: String; let type: String }

    public func ensureScaleSet(name: String, labels: [String], runnerGroup: String?) async throws -> GitHubScaleSet {
        let group = try await ensureRunnerGroup(name: runnerGroup ?? "default")
        return try await ensureScaleSet(name: name, labels: labels, runnerGroupId: group.id)
    }

    private func ensureRunnerGroup(name: String) async throws -> GitHubScaleSetRunnerGroup {
        struct GroupList: Decodable {
            let value: [GitHubScaleSetRunnerGroup]
            let count: Int?
        }
        func fetch(query: String?) async throws -> GroupList {
            let suffix = query.map { "?\($0)" } ?? ""
            let listRequest = try await adminRequest(method: "GET", path: "/_apis/runtime/runnergroups\(suffix)")
            let (data, _) = try await send(listRequest)
            return try JSONDecoder().decode(GroupList.self, from: data)
        }
        var groupComponents = URLComponents()
        groupComponents.queryItems = [URLQueryItem(name: "groupName", value: name)]
        // `groupName` is a best-effort filter (some GHES builds answer an
        // empty list for it), so an empty filtered answer falls back to the
        // full list with a local name match before declaring the group
        // missing — and a filter that comes back unfiltered is matched the
        // same way instead of erroring on the count.
        let filtered = try await fetch(query: groupComponents.percentEncodedQuery)
        if let match = filtered.value.first(where: { $0.name == name }) {
            return match
        }
        let all = try await fetch(query: nil)
        guard let match = all.value.first(where: { $0.name == name }) else {
            throw ScaleSetError.messageServiceFailure(
                reason: "runner group '\(name)' was not found; create it in GitHub before attaching")
        }
        return match
    }

    private func ensureScaleSet(name: String, labels: [String], runnerGroupId: Int) async throws -> GitHubScaleSet {
        var queryComponents = URLComponents()
        queryComponents.queryItems = [
            URLQueryItem(name: "runnerGroupId", value: String(runnerGroupId)),
            URLQueryItem(name: "name", value: name),
        ]
        let query = queryComponents.percentEncodedQuery ?? ""
        let listRequest = try await adminRequest(
            method: "GET", path: "/_apis/runtime/runnerscalesets?\(query)")
        let (data, _) = try await send(listRequest)
        struct ScaleSetList: Decodable {
            let value: [GitHubScaleSet]
            let count: Int?
        }
        let scaleSetList = try JSONDecoder().decode(ScaleSetList.self, from: data)
        let scaleSets = scaleSetList.value
        let matchCount = scaleSetList.count ?? scaleSets.count
        guard matchCount <= 1 else {
            throw ScaleSetError.messageServiceFailure(
                reason: "scale-set lookup for '\(name)' returned \(matchCount) results")
        }
        if let existing = scaleSets.first {
            if Set(existing.labels) != Set(labels) { try await patchScaleSet(id: existing.id, labels: labels) }
            return GitHubScaleSet(
                id: existing.id, name: existing.name, runnerGroupName: existing.runnerGroupName,
                labels: labels, statistics: existing.statistics)
        }
        guard matchCount == 0 else {
            throw ScaleSetError.messageServiceFailure(reason: "scale-set lookup count did not match its response")
        }
        let scaleSetBody = try JSONEncoder().encode(
            ScaleSetCreate(name: name, labels: labels, runnerGroupId: runnerGroupId))
        var create = try await adminRequest(
            method: "POST", path: "/_apis/runtime/runnerscalesets", body: scaleSetBody)
        create.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let (createdData, _) = try await send(create)
        return try JSONDecoder().decode(GitHubScaleSet.self, from: createdData)
    }

    public func patchScaleSet(id: Int, labels: [String]) async throws {
        let body = try JSONEncoder().encode(ScaleSetPatch(labels: labels))
        var request = try await adminRequest(
            method: "PATCH", path: "/_apis/runtime/runnerscalesets/\(id)", body: body)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        _ = try await send(request)
    }

    // MARK: - Sessions

    struct SessionCreate: Encodable { let ownerName: String }

    public func createSession(
        scaleSetId: Int, ownerName: String
    ) async throws -> GitHubScaleSetSession {
        let body = try JSONEncoder().encode(SessionCreate(ownerName: ownerName))
        var request = try await adminRequest(
            method: "POST", path: "/_apis/runtime/runnerscalesets/\(scaleSetId)/sessions", body: body)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let (data, _) = try await send(request)
        return try JSONDecoder().decode(GitHubScaleSetSession.self, from: data)
    }

    public func refreshSession(
        scaleSetId: Int, sessionId: String
    ) async throws -> GitHubScaleSetSession {
        let request = try await adminRequest(
            method: "PATCH", path: "/_apis/runtime/runnerscalesets/\(scaleSetId)/sessions/\(sessionId)")
        let (data, _) = try await send(request)
        return try JSONDecoder().decode(GitHubScaleSetSession.self, from: data)
    }

    public func deleteSession(scaleSetId: Int, sessionId: String) async throws {
        let request = try await adminRequest(
            method: "DELETE", path: "/_apis/runtime/runnerscalesets/\(scaleSetId)/sessions/\(sessionId)")
        _ = try await send(request)
    }

    // MARK: - Messages

    public func pollMessages(
        session: GitHubScaleSetSession, lastMessageId: String?, maxCapacity: Int
    ) async throws -> [GitHubScaleSetMessage] {
        guard var components = URLComponents(url: session.messageQueueUrl, resolvingAgainstBaseURL: false) else {
            throw ScaleSetError.messageServiceFailure(reason: "invalid message queue URL")
        }
        var queryItems = components.queryItems ?? []
        if let lastMessageId {
            queryItems.removeAll { $0.name == "lastMessageId" }
            queryItems.append(URLQueryItem(name: "lastMessageId", value: lastMessageId))
        }
        components.queryItems = queryItems
        guard let url = components.url else {
            throw ScaleSetError.messageServiceFailure(reason: "invalid message queue URL")
        }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("application/json; api-version=6.0-preview", forHTTPHeaderField: "Accept")
        request.setValue("Bearer \(session.messageQueueAccessToken)", forHTTPHeaderField: "Authorization")
        request.setValue(String(max(0, maxCapacity)), forHTTPHeaderField: "X-ScaleSetMaxCapacity")
        request.setValue("Kinhin/1.0", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await self.session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw ScaleSetError.messageServiceFailure(reason: "non-HTTP message response")
        }
        if http.statusCode == 202 { return [] }
        if http.statusCode == 401 {
            throw GitHubScaleSetClientError.messageQueueTokenExpired
        }
        guard http.statusCode == 200 else {
            throw ScaleSetError.messageServiceFailure(reason: "message poll returned \(http.statusCode)")
        }
        let messageResponse = try JSONDecoder().decode(MessageResponse.self, from: data)
        guard messageResponse.messageType == "RunnerScaleSetJobMessages" else {
            throw ScaleSetError.messageServiceFailure(reason: "unsupported message type \(messageResponse.messageType)")
        }
        let eventData = Data(messageResponse.body.utf8)
        let events = eventData.isEmpty ? [] : try JSONDecoder().decode([GitHubScaleSetJobEvent].self, from: eventData)
        return [
            GitHubScaleSetMessage(
                messageId: String(messageResponse.messageId), statistics: messageResponse.statistics, events: events)
        ]
    }

    public func ackMessage(session: GitHubScaleSetSession, messageId: String) async throws {
        guard var components = URLComponents(url: session.messageQueueUrl, resolvingAgainstBaseURL: false) else {
            throw ScaleSetError.messageServiceFailure(reason: "invalid ack URL for message \(messageId)")
        }
        guard !messageId.contains("/") else {
            throw ScaleSetError.messageServiceFailure(reason: "invalid ack message id")
        }
        if !components.path.hasSuffix("/") { components.path += "/" }
        components.path += messageId
        guard let url = components.url else {
            throw ScaleSetError.messageServiceFailure(reason: "invalid ack URL for message \(messageId)")
        }
        var request = URLRequest(url: url)
        request.httpMethod = "DELETE"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(session.messageQueueAccessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("Kinhin/1.0", forHTTPHeaderField: "User-Agent")
        let (_, response) = try await self.session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw ScaleSetError.messageServiceFailure(reason: "non-HTTP acknowledgement response")
        }
        if http.statusCode == 401 {
            throw GitHubScaleSetClientError.messageQueueTokenExpired
        }
        guard http.statusCode == 204 else {
            throw ScaleSetError.messageServiceFailure(
                reason: "message acknowledgement failed (HTTP \(http.statusCode))")
        }
    }

    private struct MessageResponse: Decodable {
        let messageId: Int
        let messageType: String
        let body: String
        let statistics: GitHubScaleSetStatistics?
    }

    // MARK: - JIT config

    struct JitConfigRequest: Encodable { let name: String; let workFolder: String }

    public func generateJitConfig(
        scaleSetId: Int, name: String, workFolder: String
    ) async throws -> GitHubScaleSetJitConfig {
        do {
            let body = try JSONEncoder().encode(JitConfigRequest(name: name, workFolder: workFolder))
            var request = try await adminRequest(
                method: "POST", path: "/_apis/runtime/runnerscalesets/\(scaleSetId)/generatejitconfig", body: body)
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            let (data, _) = try await send(request)
            return try JSONDecoder().decode(GitHubScaleSetJitConfig.self, from: data)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw ScaleSetError.jitConfigFailure(reason: error.localizedDescription)
        }
    }

    // MARK: - Statistics

    public func scaleSetStatistics(scaleSetId: Int) async throws -> GitHubScaleSetStatistics {
        let request = try await adminRequest(
            method: "GET", path: "/_apis/runtime/runnerscalesets/\(scaleSetId)")
        let (data, _) = try await send(request)
        let scaleSet = try JSONDecoder().decode(GitHubScaleSet.self, from: data)
        guard let statistics = scaleSet.statistics else {
            throw ScaleSetError.statisticsUnavailable(reason: "scale-set response did not include statistics")
        }
        return statistics
    }

    // MARK: - Runner lookup

}

// MARK: - Supporting DTOs

private struct GitHubScaleSetRunnerGroup: Decodable, Sendable, Equatable {
    let id: Int
    let name: String
}

// MARK: - Date decoding

extension JSONDecoder {
    static var scaleSetRegistrationDate: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
