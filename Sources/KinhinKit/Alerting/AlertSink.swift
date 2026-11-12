import Foundation

/// A destination for alerts. Delivery is best effort: the dispatcher logs a throw and carries on.
protocol AlertSink: Sendable {
    func send(_ event: AlertEvent) async throws
}

enum AlertError: LocalizedError, Equatable {
    case notHTTPS
    case badStatus(Int)
    case missingToken(String)
    case notConfigured

    var errorDescription: String? {
        switch self {
        // Never echo the URL: its path or query is often the webhook's secret.
        case .notHTTPS:
            return "alerts.webhook.url must be an https URL (http is allowed only for localhost, 127.0.0.1 or ::1)"
        case .badStatus(let code): return "the alert endpoint answered HTTP \(code)"
        case .missingToken(let name):
            return "no Keychain item holds the alert endpoint's token; store it with `kinhin alerts set-token \(name)`"
        case .notConfigured: return "alerts.webhook.url is not set in the config"
        }
    }

    /// Worth retrying: the endpoint or the network hiccuped, as opposed to rejecting the request.
    var isTransient: Bool {
        if case .badStatus(let code) = self { return code == 408 || code == 429 || code >= 500 }
        return false
    }
}

/// Posts a body to a URL and returns the HTTP status. The seam tests replace.
protocol AlertHTTP: Sendable {
    func post(_ url: URL, headers: [String: String], body: Data) async throws -> Int
}

struct URLSessionAlertHTTP: AlertHTTP {
    var timeout: TimeInterval = 10

    func post(_ url: URL, headers: [String: String], body: Data) async throws -> Int {
        var request = URLRequest(url: url, timeoutInterval: timeout)
        request.httpMethod = "POST"
        request.httpBody = body
        for (name, value) in headers { request.setValue(value, forHTTPHeaderField: name) }
        let (_, response) = try await URLSession.shared.data(for: request, delegate: NoRedirects())
        return (response as? HTTPURLResponse)?.statusCode ?? 0
    }
}

/// Refuses every redirect, so a 3xx reaches the caller as an error instead of a POST turned into a GET whose 2xx
/// would read as a delivered alert.
final class NoRedirects: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(
        _ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void
    ) {
        completionHandler(nil)
    }
}
