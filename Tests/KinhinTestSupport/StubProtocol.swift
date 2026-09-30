import Foundation
import Synchronization

/// Intercepts URLSession traffic for deterministic tests.
final class StubProtocol: URLProtocol {
    /// The stubbed HTTP behavior: status, body, headers. Read from CFNetwork
    /// loader threads (URLProtocol hands requests to its own queue), written
    /// from test code (`setup`/`defer`) — so the storage is mutex-guarded:
    /// ThreadSanitizer would otherwise flag every test that swaps handlers.
    private static let handlerBox = Mutex<StubHandler?>(nil)

    /// Set from test code; invoked on CFNetwork loader threads. Handlers must
    /// be `@Sendable` (and therefore only capture Sendable state).
    static var handler: StubHandler? {
        get { handlerBox.withLock { $0 } }
        set { handlerBox.withLock { $0 = newValue } }
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let handler = Self.handler else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        let (status, data, headers) = handler(request)
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: status,
            httpVersion: "HTTP/1.1",
            headerFields: headers
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

/// The handler signature `StubProtocol.handler` accepts. Marked `@Sendable`
/// because CFNetwork invokes it off the test's thread.
typealias StubHandler = @Sendable (URLRequest) -> (Int, Data, [String: String])
