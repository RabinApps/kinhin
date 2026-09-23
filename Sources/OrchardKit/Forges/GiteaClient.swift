import Foundation

#if canImport(FoundationNetworking)
    import FoundationNetworking
#endif

// MARK: - Models

/// A runner registered on a Gitea instance (unified actions-runner API shape).
public struct GiteaRunner: Codable, Sendable, Equatable {
    public let id: Int
    public let name: String
    public let status: String?

    enum CodingKeys: String, CodingKey {
        case id, name, status
    }
}

public enum GiteaError: LocalizedError, Equatable {
    case unauthorized
    case forbidden(String)
    case notFound(String)
    case http(Int, String)
    case decoding(String)
    case invalidInstance(String)

    public var errorDescription: String? {
        switch self {
        case .unauthorized:
            return "Gitea rejected the access token (401) — expired, revoked, or wrong instance. Fix: orchard auth set --gitea"
        case .forbidden(let why):
            return "Gitea forbidden (403): \(why)"
        case .notFound(let what):
            return "Gitea returned 404 for \(what) — check the scope and that Actions are enabled on the instance"
        case .http(let code, let body):
            return "Gitea HTTP \(code): \(body)"
        case .decoding(let why):
            return "Could not decode Gitea response: \(why)"
        case .invalidInstance(let url):
            return "invalid Gitea instance URL: \(url) — use https://gitea.example.com (no /api suffix)"
        }
    }
}

// MARK: - Credentials

/// One Gitea instance + scope ("owner/name" repo or bare org name).
public struct GiteaCredentials: Sendable {
    public let token: String
    public let scope: String
    /// Instance base URL, e.g. "https://gitea.example.com" (no /api suffix).
    public let instance: String

    public init(token: String, scope: String, instance: String) {
        self.token = token
        self.scope = scope
        self.instance = instance
    }

    public var isOrgScope: Bool { !scope.contains("/") }

    public var owner: String { String(scope.split(separator: "/").first ?? "") }

    /// Base for the actions sub-API of this scope.
    var actionsBase: String {
        isOrgScope
            ? "/api/v1/orgs/\(scope)/actions"
            : "/api/v1/repos/\(scope)/actions"
    }

    /// URL the in-VM act_runner registers against (the instance itself).
    public var registrationURL: String { instance }

    static func validate(instance: String) throws -> URL {
        guard let url = URL(string: instance),
              let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https",
              let host = url.host, !host.isEmpty,
              url.path.isEmpty || url.path == "/" else {
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

    // MARK: Endpoints

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

    public func deleteRunner(id: Int) async throws {
        _ = try await send(path: "\(credentials.actionsBase)/runners/\(id)", method: "DELETE")
    }

    /// Pending demand. Primary: the scope's task queue endpoints (verified on
    /// the target instance in the field). Fallback when the API answers but
    /// reports nothing usable: caller applies the min_runners floor.
    public func queuedTaskCount() async throws -> Int {
        let (data, _) = try await send(path: "\(credentials.actionsBase)/tasks?status=waiting&page=1&limit=50")
        struct TaskRef: Decodable {}
        struct Wrapper: Decodable { let total_count: Int; let entries: [TaskRef]? }
        do {
            return try JSONDecoder().decode(Wrapper.self, from: data).total_count
        } catch {
            throw GiteaError.decoding("tasks: \(error.localizedDescription)")
        }
    }

    // MARK: Plumbing

    func send(path: String, method: String = "GET") async throws -> (Data, HTTPURLResponse) {
        guard let base = try? GiteaCredentials.validate(instance: credentials.instance) else {
            throw GiteaError.invalidInstance(credentials.instance)
        }
        guard var components = URLComponents(url: base, resolvingAgainstBaseURL: false) else {
            throw GiteaError.invalidInstance(credentials.instance)
        }
        components.path = path
        guard let url = components.url else {
            throw GiteaError.invalidInstance(credentials.instance)
        }
        var req = URLRequest(url: url)
        req.httpMethod = method
        req.setValue("token \(credentials.token)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.setValue("Orchard/1.0", forHTTPHeaderField: "User-Agent")

        let (data, response) = try await session.data(for: req)
        guard let http = response as? HTTPURLResponse else {
            throw GiteaError.http(0, "non-HTTP response")
        }
        switch http.statusCode {
        case 200 ... 299:
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
