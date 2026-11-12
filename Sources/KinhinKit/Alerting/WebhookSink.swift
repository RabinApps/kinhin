import Foundation

/// Sends alerts as a JSON POST. `format` shapes the body for the receiving service, so no relay is needed.
struct WebhookSink: AlertSink {
    typealias Format = KinhinConfig.AlertsConfig.Format

    let url: URL
    let format: Format
    /// Sent as `Authorization: Bearer <token>` when set.
    let token: String?
    let http: any AlertHTTP
    /// Delay before the first retry of a transient failure (doubles per retry).
    var retryDelay: TimeInterval = 1

    /// Rejects plain `http` unless the endpoint is this Mac.
    static func validate(_ raw: String) throws -> URL {
        guard let url = URL(string: raw), let scheme = url.scheme?.lowercased(), url.host != nil else {
            throw AlertError.notHTTPS
        }
        let loopback = ["localhost", "127.0.0.1", "::1"].contains(url.host?.lowercased() ?? "")
        guard scheme == "https" || (scheme == "http" && loopback) else { throw AlertError.notHTTPS }
        return url
    }

    func send(_ event: AlertEvent) async throws {
        var (body, headers) = try Self.request(for: event, format: format)
        if let token { headers["Authorization"] = "Bearer \(token)" }
        try await withTransientRetry(
            baseDelay: retryDelay,
            isTransient: { ($0 as? AlertError)?.isTransient ?? ($0 is URLError) },
            {
                let code = try await http.post(url, headers: headers, body: body)
                guard (200..<300).contains(code) else { throw AlertError.badStatus(code) }
            })
    }

    /// The body and content headers of `event` for `format`. ntfy takes the message as the plain-text body.
    static func request(for event: AlertEvent, format: Format) throws -> (Data, [String: String]) {
        let json = ["Content-Type": "application/json"]
        switch format {
        case .generic:
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = [.sortedKeys]
            return (try encoder.encode(event), json)
        case .slack: return (try JSONSerialization.data(withJSONObject: ["text": event.summary]), json)
        case .discord: return (try JSONSerialization.data(withJSONObject: ["content": event.summary]), json)
        case .ntfy:
            return (Data(event.summary.utf8), ["Content-Type": "text/plain; charset=utf-8", "Title": "kinhin"])
        }
    }
}
