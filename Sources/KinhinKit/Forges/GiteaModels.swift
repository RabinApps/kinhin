import Foundation

// Wire models for the Gitea actions API and the error surface of its client.

/// A runner registered on a Gitea instance (unified actions-runner API shape).
public struct GiteaRunner: Codable, Sendable, Equatable {
    public let id: Int
    public let name: String
    public let status: String?

    enum CodingKeys: String, CodingKey {
        case id, name, status
    }
}

/// One entry of the instance's task queue (`/actions/tasks`). Field shapes
/// vary across Gitea versions, so decoding is defensive: anything that can
/// be missing is optional, and an entry with no usable name still yields a
/// count (the engine degrades attribution, never demand).
public struct GiteaTask: Sendable, Equatable {
    public let id: Int?
    /// Task or workflow name ("build", "Nightly / build"); nil when the
    /// entry's name fields are absent.
    public let name: String?
    /// `owner/name` of the repository the task belongs to, when the instance
    /// exposes attribution (repo-scoped queues may not).
    public let repository: String?
    /// Raw status string ("waiting", "running").
    public let status: String?
    /// The runner (→ VM) executing the task; running tasks only.
    public let runnerName: String?

    public init(id: Int?, name: String?, repository: String?, status: String?, runnerName: String? = nil) {
        self.id = id
        self.name = name
        self.repository = repository
        self.status = status
        self.runnerName = runnerName
    }
}

enum GiteaError: LocalizedError, Equatable {
    case unauthorized
    case forbidden(String)
    case notFound(String)
    case http(Int, String)
    case decoding(String)
    case invalidInstance(String)

    public var errorDescription: String? {
        switch self {
        case .unauthorized:
            return
                "Gitea rejected the access token (401) — expired, revoked, or wrong instance. Fix: kinhin auth set --gitea"
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
