import Foundation
import Network
import Synchronization

/// A minimal HTTP listener serving `GET /metrics` for a Prometheus scrape. Bound to exactly the
/// configured address (loopback unless the config says otherwise), serves nothing but `/metrics`,
/// and closes every connection after one response.
///
/// The SDK's own Prometheus server is not used: its `start()` blocks its caller for the server's
/// whole life and it ends the process on a shutdown error, neither of which a long-running daemon
/// that reloads its config can accept.
final class PrometheusListener: Sendable {
    private let listener: NWListener
    // Network.framework delivers its callbacks on a DispatchQueue.
    private let queue = DispatchQueue(label: "kinhin.telemetry.prometheus")  // rules-lint: allow legacy-sync
    private let body: @Sendable () -> String
    /// The port actually bound (differs from the requested one only for port 0).
    let port: Int

    /// Binds and starts listening; throws when the address cannot be bound (in use, not local, denied).
    init(address: TelemetryListenAddress, body: @escaping @Sendable () -> String) throws {
        self.body = body
        let parameters = NWParameters.tcp
        parameters.allowLocalEndpointReuse = true
        let host = NWEndpoint.Host(address.host)
        let requestedPort = address.port == 0 ? NWEndpoint.Port.any : NWEndpoint.Port(rawValue: UInt16(address.port))
        guard let requestedPort else { throw TelemetryError.listenFailed("port \(address.port) is out of range") }
        parameters.requiredLocalEndpoint = .hostPort(host: host, port: requestedPort)
        let listener: NWListener
        do {
            listener = try NWListener(using: parameters)
        } catch {
            throw TelemetryError.listenFailed("\(address.host):\(address.port): \(error.localizedDescription)")
        }
        self.listener = listener

        // The init waits once for the listener to report ready or failed.
        let ready = DispatchSemaphore(value: 0)  // rules-lint: allow legacy-sync
        let outcome = Mutex<Result<Void, Error>?>(nil)
        listener.stateUpdateHandler = { state in
            switch state {
            case .ready:
                outcome.withLock { $0 = $0 ?? .success(()) }
                ready.signal()
            case .failed(let error):
                outcome.withLock { $0 = $0 ?? .failure(error) }
                ready.signal()
            default:
                break
            }
        }
        let body = self.body
        let queue = self.queue
        listener.newConnectionHandler = { connection in
            Self.serve(connection, on: queue, body: body)
        }
        listener.start(queue: queue)
        guard ready.wait(timeout: .now() + 3) == .success, let result = outcome.withLock({ $0 }) else {
            listener.cancel()
            throw TelemetryError.listenFailed("\(address.host):\(address.port): timed out")
        }
        if case .failure(let error) = result {
            listener.cancel()
            throw TelemetryError.listenFailed("\(address.host):\(address.port): \(error.localizedDescription)")
        }
        self.port = listener.port.map { Int($0.rawValue) } ?? address.port
    }

    func stop() {
        listener.stateUpdateHandler = nil
        listener.cancel()
    }

    private static func serve(
        _ connection: NWConnection, on queue: DispatchQueue,  // rules-lint: allow legacy-sync
        body: @escaping @Sendable () -> String
    ) {
        connection.start(queue: queue)
        connection.receive(minimumIncompleteLength: 1, maximumLength: 8192) { data, _, _, error in
            guard error == nil, let data else {
                connection.cancel()
                return
            }
            let response = Self.response(forRequest: String(decoding: data, as: UTF8.self), body: body)
            connection.send(
                content: Data(response.utf8),
                completion: .contentProcessed { _ in connection.cancel() })
        }
    }

    /// The HTTP response for a raw request: `/metrics` (query allowed) for GET and HEAD, else 404 or 405.
    static func response(forRequest request: String, body: () -> String) -> String {
        let line = request.split(separator: "\r\n", maxSplits: 1, omittingEmptySubsequences: false).first ?? ""
        let parts = line.split(separator: " ")
        guard parts.count >= 2 else { return status(400, "Bad Request") }
        let method = parts[0]
        let path = parts[1].split(separator: "?", maxSplits: 1).first.map(String.init) ?? ""
        guard path == "/metrics" else { return status(404, "Not Found") }
        guard method == "GET" || method == "HEAD" else { return status(405, "Method Not Allowed") }
        let text = body()
        let head =
            "HTTP/1.1 200 OK\r\nContent-Type: text/plain; version=0.0.4; charset=utf-8\r\n"
            + "Content-Length: \(text.utf8.count)\r\nConnection: close\r\n\r\n"
        return method == "HEAD" ? head : head + text
    }

    private static func status(_ code: Int, _ reason: String) -> String {
        "HTTP/1.1 \(code) \(reason)\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
    }
}
