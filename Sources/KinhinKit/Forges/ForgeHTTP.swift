import Foundation

/// The HTTP plumbing the GitHub, Gitea-family and GitLab clients share: one
/// session configuration and one rule for which failures are worth a retry.
enum ForgeHTTP {
    /// The session a client uses: the injected one (tests stub it), else a
    /// shared session with 30 s per request, 60 s per resource, no HTTP
    /// cache, and no waiting for connectivity (an offline Mac fails fast and retries on
    /// the next poll).
    static func session(_ injected: URLSession?) -> URLSession {
        injected ?? shared
    }

    /// Hosts that never leave this machine; plain http to them leaks nothing.
    static func isLoopback(host: String) -> Bool {
        let host = host.lowercased()
        return host == "localhost" || host.hasSuffix(".localhost") || host == "127.0.0.1" || host == "::1"
            || host == "[::1]"
    }

    /// The scheme rule for a self-hosted instance URL: https always; http only
    /// to loopback or when the account opted in (`allow_insecure_http`).
    static func permitsScheme(of url: URL, allowInsecureHTTP: Bool) -> Bool {
        switch url.scheme?.lowercased() {
        case "https": return true
        case "http": return allowInsecureHTTP || isLoopback(host: url.host ?? "")
        default: return false
        }
    }

    /// Whether a request may follow a redirect: same host, and never from
    /// https down to http. Credentials ride on the original request's headers
    /// (some, like GitLab's `PRIVATE-TOKEN`, are not stripped by Foundation on
    /// a cross-host hop), so a redirect elsewhere would hand them over.
    static func allowsRedirect(from original: URL?, to target: URL?) -> Bool {
        guard let original, let target,
            let fromHost = original.host?.lowercased(), let toHost = target.host?.lowercased(),
            fromHost == toHost
        else { return false }
        let fromScheme = original.scheme?.lowercased()
        let toScheme = target.scheme?.lowercased()
        if fromScheme == "https" { return toScheme == "https" }
        return toScheme == "http" || toScheme == "https"
    }

    /// Refuses redirects that `allowsRedirect` rejects; the 3xx response then
    /// reaches the client, which reports it as an HTTP error.
    private final class RedirectGuard: NSObject, URLSessionTaskDelegate, Sendable {
        func urlSession(
            _ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
            newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void
        ) {
            if ForgeHTTP.allowsRedirect(from: task.originalRequest?.url, to: request.url) {
                completionHandler(request)
            } else {
                Log.warn("forge", "refused a redirect to a different host or a downgrade to http")
                completionHandler(nil)
            }
        }
    }

    private static let shared: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 30
        config.timeoutIntervalForResource = 60
        config.waitsForConnectivity = false
        // Polls must see the forge's current answer: GitHub marks reads
        // max-age=60, which the system cache would serve stale. Revalidation
        // is the clients' own job (GitHub: `ConditionalGetCache`).
        config.urlCache = nil
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(configuration: config, delegate: RedirectGuard(), delegateQueue: nil)
    }()

    /// A network-layer failure (offline, DNS, timeout) worth another
    /// attempt. A cancelled request is not: cancellation must propagate.
    static func isTransientNetworkError(_ error: Error) -> Bool {
        guard let error = error as? URLError else { return false }
        return error.code != .cancelled
    }

    /// An HTTP status worth another attempt: no usable response (0), rate
    /// limiting (429) or a server error (5xx).
    static func isTransientStatus(_ code: Int) -> Bool {
        code == 0 || code == 429 || code >= 500
    }
}
