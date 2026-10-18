import Foundation
import Synchronization

@testable import KinhinKit
@testable import KinhinTestSupport

/// Helpers shared by the Ollama advisor tests: a session that answers from
/// `StubProtocol`, the request's JSON body, and a request the advisors share.
enum OllamaTestSupport {
    static let host = URL(string: "http://127.0.0.1:11434")!

    static func session() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubProtocol.self]
        return URLSession(configuration: config)
    }

    static let request = HealingAdviceRequest(
        signal: HealingSignal(kind: .queueUnreadable, subject: "gitea", detail: "HTTP 503 from gitea.local"),
        candidates: [Remediation(.retryForgeAttach, subject: "gitea")],
        context: "warn engine: queue fetch failed for gitea: HTTP 503")

    /// A JSON reply body for `StubProtocol`.
    static func json(_ text: String) -> Data {
        Data(text.utf8)
    }
}

extension URLRequest {
    /// URLProtocol receives POST bodies as a stream; read the raw bytes back.
    func ollamaBodyData() -> Data {
        if let httpBody { return httpBody }
        guard let stream = httpBodyStream else { return Data() }
        stream.open()
        defer { stream.close() }
        var read = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            if count <= 0 { break }
            read.append(buffer, count: count)
        }
        return read
    }
}

/// Records the body of every request a stub answers, as raw bytes (so it
/// stays Sendable); `last` parses the most recent one.
final class OllamaRequestLog: Sendable {
    private let bodies = Mutex<[Data]>([])

    func record(_ request: URLRequest) {
        let data = request.ollamaBodyData()
        bodies.withLock { $0.append(data) }
    }

    var last: [String: Any]? {
        guard let data = bodies.withLock({ $0.last }) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }
}
