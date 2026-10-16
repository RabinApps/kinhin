import Foundation

/// The HTTP calls the Ollama advisors make, against one server. Plain
/// `URLSession` with JSON bodies: the `/v1/systemone` decision endpoint is not
/// in Ollama's client libraries, so one thin client serves both tiers, and
/// tests drive it through `StubProtocol`.
struct OllamaClient: Sendable {
    let host: URL
    let session: URLSession

    /// Ephemeral: no cache or cookies for a local model server.
    static let defaultSession = URLSession(configuration: .ephemeral)

    /// Seconds for the availability probes, which must answer quickly.
    static let probeTimeout: TimeInterval = 10

    init(host: URL, session: URLSession = OllamaClient.defaultSession) {
        self.host = host
        self.session = session
    }

    /// The models the server has, by full name (`name:tag`).
    func modelNames() async throws -> [String] {
        let data = try await send("api/tags", body: nil, timeout: Self.probeTimeout)
        return try JSONDecoder().decode(Tags.self, from: data).models.map(\.name)
    }

    /// The server's version, such as `0.40.4`.
    func version() async throws -> String {
        let data = try await send("api/version", body: nil, timeout: Self.probeTimeout)
        return try JSONDecoder().decode(Version.self, from: data).version
    }

    /// Whether the server is up, has `model` pulled, and is at least
    /// `minimumVersion`. Any failure is "not ready": the problem is then shown
    /// as if there were no advisor, and the reason goes to the log. A cancelled
    /// probe is "not ready" too, but the caller must not cache it (see
    /// `HealingAgent.advisorIsAvailable`).
    func isReady(model: String, minimumVersion: String) async -> Bool {
        do {
            guard Self.has(model, in: try await modelNames()) else { return false }
            return Self.isVersion(try await version(), atLeast: minimumVersion)
        } catch {
            if Task.isCancelled { return false }
            // Only the host is logged: the full URL could carry credentials.
            let server = host.host ?? "?"
            Log.info("healing", "Ollama at \(server) is not ready for \(model): \(error.localizedDescription)")
            return false
        }
    }

    /// Serializes a request body. The advisors do this before the deadline
    /// closure, so the closure captures only `Data`.
    static func encode(_ body: [String: Any]) throws -> Data {
        try JSONSerialization.data(withJSONObject: body)
    }

    /// POSTs a JSON `body` to `path` and returns the reply's body.
    func post(_ path: String, body: Data, timeout: TimeInterval) async throws -> Data {
        try await send(path, body: body, timeout: timeout)
    }

    /// Whether `name` is one of `models`. A name without a tag matches `name:latest`.
    static func has(_ name: String, in models: [String]) -> Bool {
        models.contains(name.contains(":") ? name : name + ":latest")
    }

    /// Whether dotted `version` is at least `minimum`, comparing numbers
    /// part by part (`0.40.4` against `0.35.1`); a pre-release suffix is ignored.
    static func isVersion(_ version: String, atLeast minimum: String) -> Bool {
        func parts(_ text: String) -> [Int] {
            text.split(separator: ".").map { Int($0.prefix(while: { $0.isNumber })) ?? 0 }
        }
        let have = parts(version)
        let want = parts(minimum)
        for index in 0..<max(have.count, want.count) {
            let a = index < have.count ? have[index] : 0
            let b = index < want.count ? want[index] : 0
            if a != b { return a > b }
        }
        return true
    }

    private func send(_ path: String, body: Data?, timeout: TimeInterval) async throws -> Data {
        var request = URLRequest(url: host.appending(path: path))
        request.timeoutInterval = timeout
        if let body {
            request.httpMethod = "POST"
            request.httpBody = body
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            throw EngineError.healingFailed("Ollama answered HTTP \(status) on /\(path)")
        }
        return data
    }

    private struct Tags: Decodable {
        let models: [Model]

        struct Model: Decodable {
            let name: String
        }
    }

    private struct Version: Decodable {
        let version: String
    }
}
