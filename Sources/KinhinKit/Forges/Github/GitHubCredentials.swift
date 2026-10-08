import Foundation

public struct GitHubCredentials: Sendable {
    public let token: String
    /// GitHub scope the fleet serves: "owner/name" (one repository) or a
    /// single "org" segment (an entire organization — runners register at
    /// the org level and serve every repo's queued jobs).
    public let scope: String
    /// The GitHub instance base URL. Nil means github.com; a GHES host
    /// ("https://HOST") or a GHEC data-residency host ("https://HOST")
    /// changes every API base, the runner registration URL and token-creation
    /// links. `allowInsecureHTTP` controls the scheme rule for self-hosted
    /// instances (loopback http is always allowed).
    public let instance: String?
    public let allowInsecureHTTP: Bool

    public init(token: String, scope: String, instance: String? = nil, allowInsecureHTTP: Bool = false) {
        self.token = token
        self.scope = scope
        self.instance = instance
        self.allowInsecureHTTP = allowInsecureHTTP
    }

    /// True when the scope is an organization, not a single repository.
    var isOrgScope: Bool { !scope.contains("/") }

    /// The owner segment of the scope ("acme" in "acme/api").
    public var owner: String { String(scope.split(separator: "/").first ?? "") }

    /// The REST base URL for this scope's Actions API. github.com stays at
    /// api.github.com; a `*.ghe.com` data-residency host uses `api.<host>`;
    /// any other host uses `<host>/api/v3`.
    var apiBase: String {
        guard let instance else { return "https://api.github.com" }
        guard let url = URL(string: instance), let host = url.host else {
            return "https://api.github.com"
        }
        if host.hasSuffix(".ghe.com") {
            return "https://api.\(host)"
        }
        return "https://\(host)/api/v3"
    }

    /// The web base for this instance: where token-creation and settings links
    /// point. github.com stays at github.com; a `*.ghe.com` host uses the
    /// host as-is; any other host is the instance URL's host.
    var webBase: String {
        guard let instance, let url = URL(string: instance), let host = url.host else {
            return "https://github.com"
        }
        if host.hasSuffix(".ghe.com") { return "https://\(host)" }
        return "https://\(host)"
    }

    /// URL passed to the runner's `config.sh --url`: GitHub's documented form
    /// is `https://github.com/<org>` for org runners and
    /// `https://github.com/<owner>/<repo>` for repo runners (the
    /// `/organizations/<org>` form answers 404 from runner-registration).
    var configureURL: String { "\(webBase)/\(scope)" }

    /// REST path prefix for the Actions API of this scope.
    var actionsBase: String {
        isOrgScope
            ? "/orgs/\(scope)/actions"
            : "/repos/\(scope)/actions"
    }

    /// Validates an enterprise instance URL the way `GitLabCredentials` does:
    /// an http(s) URL with a host, scheme allowed by the account's
    /// `allowInsecureHTTP`, and no `/api` path suffix (the client appends its
    /// own prefix where needed).
    static func validate(instance: String, allowInsecureHTTP: Bool = false) throws -> URL {
        guard let url = URL(string: instance),
            ForgeHTTP.permitsScheme(of: url, allowInsecureHTTP: allowInsecureHTTP),
            let host = url.host, !host.isEmpty,
            !url.path.split(separator: "/").contains("api")
        else {
            throw GitHubError.invalidInstance(instance)
        }
        return url
    }
}

extension GitHubCredentials {
    /// The host the API base for this scope resolves to (nil for github.com).
    /// Callers that need to pin pagination or validate a redirect target can
    /// compare against this host, which is the same one `request` builds URLs
    /// against.
    var apiHost: String? {
        guard let instance, let url = URL(string: instance), let host = url.host else { return nil }
        return host
    }

    /// An error view that includes the enterprise host, useful for token-check
    /// and doctor messages that must tell the user *which* GitHub instance the
    /// token was talking to.
    var instanceLabel: String {
        apiBase
    }

    /// True when this scope is served by a non-github.com instance: any GHES
    /// host or a GHEC data-residency host. The token-creation URLs used in
    /// `TokenRequirements` and the runner-registration flow must point at this
    /// host rather than github.com.
    var isEnterprise: Bool { instance != nil }
}

// MARK: - GitHubAPI

/// The request headers every GitHub REST call carries. All API flavors
/// (api.github.com, api.<sub>.ghe.com, GHES `/api/v3`) document the version
/// header; a per-instance override is a later refinement.
enum GitHubAPI {
    static let version = "2022-11-28"
    static let accept = "application/vnd.github+json"

    /// Sets Accept, User-Agent and the API version on `request`.
    static func apply(to request: inout URLRequest, accept: String = GitHubAPI.accept) {
        request.setValue(accept, forHTTPHeaderField: "Accept")
        request.setValue(ForgeHTTP.userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue(version, forHTTPHeaderField: "X-GitHub-Api-Version")
    }
}
