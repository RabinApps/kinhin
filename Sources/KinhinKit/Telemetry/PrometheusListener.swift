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
    private let idleTimeout: TimeInterval
    private let open = Locked(0)
    static let maxConnections = 16
    static let maxRequestBytes = 16 * 1024
    /// The port actually bound (differs from the requested one only for port 0).
    private let boundPort = Locked(0)
    var port: Int { boundPort.withLock { $0 } }

    /// Binds and starts listening; throws when the address cannot be bound (in use, not local, denied).
    init(
        address: TelemetryListenAddress, idleTimeout: TimeInterval = 5, body: @escaping @Sendable () -> String
    ) throws {
        self.body = body
        self.idleTimeout = idleTimeout
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
        listener.newConnectionHandler = { [self] connection in serve(connection) }
        listener.start(queue: queue)
        guard ready.wait(timeout: .now() + 3) == .success, let result = outcome.withLock({ $0 }) else {
            listener.cancel()
            throw TelemetryError.listenFailed("\(address.host):\(address.port): timed out")
        }
        if case .failure(let error) = result {
            listener.cancel()
            throw TelemetryError.listenFailed("\(address.host):\(address.port): \(error.localizedDescription)")
        }
        let bound = listener.port.map { Int($0.rawValue) } ?? address.port
        boundPort.withLock { $0 = bound }
    }

    func stop() {
        listener.stateUpdateHandler = nil
        listener.cancel()
    }

    /// A request is read until its blank line (or the size cap); a client that never finishes is dropped after
    /// `idleTimeout`, and at most `maxConnections` are served at once, so a stuck scraper cannot hold the daemon's
    /// file descriptors.
    private func serve(_ connection: NWConnection) {
        let admitted = open.withLock { count -> Bool in
            guard count < Self.maxConnections else { return false }
            count += 1
            return true
        }
        guard admitted else {
            connection.cancel()
            return
        }
        let finished = Locked(false)
        let close: @Sendable () -> Void = { [open] in
            let first = finished.withLock { done -> Bool in
                defer { done = true }
                return !done
            }
            guard first else { return }
            open.withLock { $0 -= 1 }
            connection.cancel()
        }
        connection.start(queue: queue)
        queue.asyncAfter(deadline: .now() + idleTimeout) { close() }
        receive(connection, buffer: Data(), close: close)
    }

    private func receive(_ connection: NWConnection, buffer: Data, close: @escaping @Sendable () -> Void) {
        let body = self.body
        connection.receive(minimumIncompleteLength: 1, maximumLength: 4096) { [self] data, _, isComplete, error in
            guard error == nil else { return close() }
            var buffer = buffer
            if let data { buffer.append(data) }
            let text = String(decoding: buffer, as: UTF8.self)
            if text.contains("\r\n\r\n") || text.contains("\n\n") || buffer.count >= Self.maxRequestBytes {
                let response = Self.response(forRequest: text, body: body)
                connection.send(content: Data(response.utf8), completion: .contentProcessed { _ in close() })
            } else if isComplete {
                close()
            } else {
                receive(connection, buffer: buffer, close: close)
            }
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
