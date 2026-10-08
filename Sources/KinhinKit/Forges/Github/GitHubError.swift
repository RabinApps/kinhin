import Foundation

public enum GitHubError: LocalizedError, CategorizedError, Equatable, Sendable {
    case unauthorized
    case forbidden(String)
    case notFound(String)
    case rateLimited(resetAt: Date)
    case http(Int, String)
    case decoding(String)
    case invalidInstance(String)

    /// Only credential and access problems point at the token; an outage,
    /// rate limit or malformed response must not tell the user to re-enter it.
    public var category: ErrorCategory {
        switch self {
        case .unauthorized, .forbidden, .notFound: return .auth
        case .invalidInstance: return .config
        case .rateLimited, .http, .decoding: return .runtime
        }
    }

    public var errorDescription: String? {
        switch self {
        case .unauthorized:
            return
                "GitHub rejected the token (401). Check it with `kinhin auth status` — it may be expired or lack the required scopes."
        case .forbidden(let why):
            return "GitHub forbidden (403): \(why)"
        case .notFound(let what):
            if what.hasPrefix("/orgs/"), what.contains("/actions/runs") {
                return
                    "GitHub returned 404 for \(what): the token cannot read this organization's workflow runs. "
                    + "Kinhin reads runs per repository; check the token's repository access and Actions: Read-only permission."
            }
            if what.hasSuffix("/*/actions/runs") {
                return
                    "GitHub returned 404 for \(what): the token cannot read workflow runs in any repository of the scope. "
                    + "Fine-grained tokens need Repository permissions → Actions: Read-only; a classic token with the repo scope always works."
            }

            return "GitHub returned 404 for \(what). Does the repo exist and does the token have access to it?"
        case .rateLimited(let resetAt):
            return "GitHub rate limit exhausted; resets at \(resetAt)"
        case .http(let code, let body):
            return "GitHub HTTP \(code): \(body)"
        case .decoding(let why):
            return "Could not decode GitHub response: \(why)"
        case .invalidInstance(let url):
            return
                "invalid GitHub enterprise instance URL: \(url). Use the base URL (e.g. https://github.example.com or https://SUB.ghe.com), not an /api path"
        }
    }
}
