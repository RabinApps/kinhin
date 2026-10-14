import Foundation

public enum GitHubError: LocalizedError, CategorizedError, Equatable, Sendable {
    case unauthorized
    case forbidden(String)
    case notFound(String)
    case rateLimited(resetAt: Date)
    case http(Int, String)
    case decoding(String)
    case invalidInstance(String)

    // Scale-set (Actions service) failures. The listener reports the ones in
    // `isScaleSetFailure` verbatim; any other error is wrapped in one of them.
    /// The message-queue token expired; the caller refreshes the session and retries.
    case scaleSetMessageQueueTokenExpired
    /// GitHub still holds an earlier session for this scale set (409).
    case scaleSetSessionConflict
    /// A queue action (requeue / skip) the scale-set listener cannot perform.
    case scaleSetQueueActionUnsupported(action: String)
    case scaleSetNoSession(reason: String)
    case scaleSetSessionRefreshFailed(reason: String)
    case scaleSetAdminTokenFailure(reason: String)
    case scaleSetIdFailure(reason: String)
    case scaleSetStatisticsUnavailable(reason: String)
    case scaleSetMessageServiceFailure(reason: String)
    case scaleSetJITConfigFailure(reason: String)

    /// Only credential and access problems point at the token; an outage,
    /// rate limit or malformed response must not tell the user to re-enter it.
    public var category: ErrorCategory {
        switch self {
        case .unauthorized, .forbidden, .notFound: return .auth
        case .invalidInstance: return .config
        case .rateLimited, .http, .decoding: return .runtime
        case .scaleSetMessageQueueTokenExpired, .scaleSetSessionConflict, .scaleSetQueueActionUnsupported,
            .scaleSetNoSession, .scaleSetSessionRefreshFailed, .scaleSetAdminTokenFailure, .scaleSetIdFailure,
            .scaleSetStatisticsUnavailable, .scaleSetMessageServiceFailure, .scaleSetJITConfigFailure:
            // A listener/session failure: the wrapped reason may be an auth problem, but the
            // scale-set error itself is not a rejected token.
            return .runtime
        }
    }

    /// The listener-side failures the scale-set listener reports as they are;
    /// any other error it wraps in one of these before reporting.
    var isScaleSetFailure: Bool {
        switch self {
        case .scaleSetNoSession, .scaleSetSessionRefreshFailed, .scaleSetAdminTokenFailure, .scaleSetIdFailure,
            .scaleSetStatisticsUnavailable, .scaleSetMessageServiceFailure, .scaleSetJITConfigFailure:
            return true
        default:
            return false
        }
    }

    /// `error` when it is already a scale-set failure (`isScaleSetFailure`), otherwise `fallback`.
    static func scaleSetFailure(_ error: Error, or fallback: GitHubError) -> GitHubError {
        if let error = error as? GitHubError, error.isScaleSetFailure { return error }
        return fallback
    }

    public var errorDescription: String? {
        switch self {
        case .unauthorized:
            return
                "GitHub rejected the token (401). Check it with `kinhin auth status` — it may be expired or lack the required scopes. "
                + "Fix: \(AuthFix.command(forge: .github, account: nil)) with a new token"
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
        case .scaleSetMessageQueueTokenExpired:
            return "scale-set message queue token expired"
        case .scaleSetSessionConflict:
            return
                "scale-set session conflict: GitHub still holds an earlier session for this scale set "
                + "(a previous run that did not shut down cleanly, or another kinhin instance); "
                + "retrying until it expires"
        case .scaleSetQueueActionUnsupported(let action):
            return
                "\(action) is not supported for scale-set accounts: jobs are delivered by GitHub, not read from a queue"
        case .scaleSetNoSession(let reason):
            return "scale-set session is not active: \(reason)"
        case .scaleSetSessionRefreshFailed(let reason):
            return "scale-set session refresh failed: \(reason)"
        case .scaleSetAdminTokenFailure(let reason):
            return "scale-set admin token unavailable: \(reason)"
        case .scaleSetIdFailure(let reason):
            return "scale-set id unavailable: \(reason)"
        case .scaleSetStatisticsUnavailable(let reason):
            return "scale-set statistics unavailable: \(reason)"
        case .scaleSetMessageServiceFailure(let reason):
            return "scale-set message service failed: \(reason)"
        case .scaleSetJITConfigFailure(let reason):
            return "scale-set JIT config generation failed: \(reason)"
        }
    }

    /// The error for a non-2xx response, shared by the REST and scale-set
    /// clients. A 403 that carries `Retry-After` or a spent rate-limit budget
    /// is a rate limit (`resetAt` says when it lifts); any other 403 is a
    /// permissions refusal.
    static func from(_ http: HTTPURLResponse, body: Data, path: String, now: Date = Date()) -> GitHubError {
        let text = String(decoding: body.prefix(500), as: UTF8.self)
        switch http.statusCode {
        case 401:
            return .unauthorized
        case 403:
            if let reset = ForgeRetryPolicy.rateLimitReset(http) { return .rateLimited(resetAt: reset) }
            if let wait = ForgeRetryPolicy.requestedWait(http, now: now) {
                return .rateLimited(resetAt: now.addingTimeInterval(wait))
            }
            return .forbidden(text)
        case 404:
            return .notFound(path)
        default:
            return .http(http.statusCode, text)
        }
    }
}
