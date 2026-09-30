import Foundation

/// The HTTP plumbing the GitHub, Gitea-family and GitLab clients share: one
/// session configuration and one rule for which failures are worth a retry.
enum ForgeHTTP {
    /// The session a client uses: the injected one (tests stub it), else a
    /// shared session with 30 s per request, 60 s per resource, and no
    /// waiting for connectivity (an offline Mac fails fast and retries on
    /// the next poll).
    static func session(_ injected: URLSession?) -> URLSession {
        injected ?? shared
    }

    private static let shared: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 30
        config.timeoutIntervalForResource = 60
        config.waitsForConnectivity = false
        return URLSession(configuration: config)
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
