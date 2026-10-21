import Foundation

/// Minimal JSON-over-HTTP client for talking to a forge fixture directly (not through kinhin).
public enum Http {
    public struct Response: Sendable {
        public let status: Int
        public let data: Data
        public var text: String { String(decoding: data, as: UTF8.self) }
        public var json: Any? { try? JSONSerialization.jsonObject(with: data) }
        public var ok: Bool { (200..<300).contains(status) }
    }

    public static func request(
        _ method: String, _ url: String, headers: [String: String] = [:], body: Data? = nil, timeout: TimeInterval = 30
    ) async throws -> Response {
        guard let target = URL(string: url) else { throw E2EError.failed("bad URL \(url)") }
        var request = URLRequest(url: target, timeoutInterval: timeout)
        request.httpMethod = method
        for (key, value) in headers { request.setValue(value, forHTTPHeaderField: key) }
        if let body {
            request.httpBody = body
            // JSON unless the caller named a type (a form post to Bitbucket's `src`).
            if request.value(forHTTPHeaderField: "Content-Type") == nil {
                request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            }
        }
        let (data, response) = try await URLSession.shared.data(for: request)
        return Response(status: (response as? HTTPURLResponse)?.statusCode ?? 0, data: data)
    }

    /// Encodes a JSON object (done at the call site, so non-Sendable `Any` never crosses an isolation boundary).
    public static func encode(_ object: Any) throws -> Data {
        try JSONSerialization.data(withJSONObject: object)
    }

    public static func waitUntilUp(_ url: String, timeout: TimeInterval) async throws {
        try await eventually("\(url) to answer", timeout: timeout, interval: 2) {
            guard let response = try? await request("GET", url, timeout: 5), response.ok else { return nil as Bool? }
            return true
        }
    }
}
