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
    /// Branch/tag and commit the task runs at, when the instance reports them.
    public let ref: String?
    public let sha: String?
    /// The run's page, its display title and number, and when it started,
    /// when the instance reports them.
    let url: String?
    let title: String?
    let runNumber: Int?
    let startedAt: String?

    public init(
        id: Int?, name: String?, repository: String?, status: String?, runnerName: String? = nil, ref: String? = nil,
        sha: String? = nil, url: String? = nil, title: String? = nil, runNumber: Int? = nil,
        startedAt: String? = nil
    ) {
        self.url = url
        self.title = title
        self.runNumber = runNumber
        self.startedAt = startedAt
        self.id = id
        self.name = name
        self.repository = repository
        self.status = status
        self.runnerName = runnerName
        self.ref = ref
        self.sha = sha
    }
}

/// Gitea-specific failures (Forgejo included). The HTTP-shaped API errors
/// (401/403/404/5xx, decoding) come from the shared transport as
/// `ForgeAPIError`.
enum GiteaError: LocalizedError, Equatable {
    case invalidInstance(String)

    var errorDescription: String? {
        switch self {
        case .invalidInstance(let url):
            return "invalid Gitea instance URL: \(url) — use https://gitea.example.com (no /api suffix)"
        }
    }
}
