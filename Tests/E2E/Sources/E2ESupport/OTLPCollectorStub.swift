import Darwin
import Foundation

/// A local stand-in for an OTLP/HTTP collector: it accepts any POST (answering 200 with an empty protobuf response, which
/// is a valid `Export*ServiceResponse`) and records the path, content type and size of each. It also notes whether the
/// (gunzipped, when `Content-Encoding: gzip`) body mentions `kinhin.`, so tests can tell kinhin's own signals from noise
/// without decoding protobuf. `GET /__requests` returns the record. Runs as a small Python server like `MusicLibraryStub`.
public final class OTLPCollectorStub: @unchecked Sendable {
    public struct Request: Sendable {
        public let path: String
        public let contentType: String
        public let bytes: Int
        public let mentionsKinhin: Bool
    }

    public let port: Int
    /// The base URL an OTLP/HTTP exporter is given; the exporter appends `/v1/metrics`, `/v1/traces`, `/v1/logs`.
    public var endpoint: String { "http://127.0.0.1:\(port)" }
    private let process = Process()
    private let directory: URL

    public init() async throws {
        guard FileManager.default.isExecutableFile(atPath: "/usr/bin/python3") else {
            throw E2EError.unavailable("python3 is needed for the OTLP collector stand-in (xcode-select --install)")
        }
        port = try E2E.freePort()
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("ke2e-otlp-\(E2E.randomID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let script = directory.appendingPathComponent("server.py")
        try Data(Self.script.utf8).write(to: script)
        process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        process.arguments = [script.path, String(port)]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        let port = self.port
        try await eventually("the OTLP collector stand-in to answer", timeout: 20, interval: 0.2) {
            let response = try? await Http.request("GET", "http://127.0.0.1:\(port)/__requests", timeout: 2)
            return response?.ok == true ? true : nil as Bool?
        }
    }

    public func stop() {
        if process.isRunning { process.terminate() }
        try? FileManager.default.removeItem(at: directory)
    }

    /// Every POST received so far, in order.
    public func requests() async -> [Request] {
        guard let response = try? await Http.request("GET", "http://127.0.0.1:\(port)/__requests", timeout: 5),
            let items = response.json as? [[String: Any]]
        else { return [] }
        return items.map {
            Request(
                path: $0["path"] as? String ?? "", contentType: $0["content_type"] as? String ?? "",
                bytes: $0["bytes"] as? Int ?? 0, mentionsKinhin: $0["mentions_kinhin"] as? Bool ?? false)
        }
    }

    /// The requests posted to exactly `path` (for example `/v1/metrics`).
    public func requests(to path: String) async -> [Request] {
        await requests().filter { $0.path == path }
    }

    private static let script = #"""
        import gzip, json, sys
        from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

        port = int(sys.argv[1])
        seen = []

        class Handler(BaseHTTPRequestHandler):
            def log_message(self, *args): pass

            def reply(self, status, body, kind):
                self.send_response(status)
                self.send_header("Content-Type", kind)
                self.send_header("Content-Length", str(len(body)))
                self.end_headers()
                self.wfile.write(body)

            def do_GET(self):
                if self.path == "/__requests":
                    return self.reply(200, json.dumps(seen).encode(), "application/json")
                self.reply(404, b"", "text/plain")

            def do_POST(self):
                body = self.rfile.read(int(self.headers.get("Content-Length", "0")))
                if self.headers.get("Content-Encoding") == "gzip":
                    try: body = gzip.decompress(body)
                    except Exception: pass
                seen.append({
                    "path": self.path.split("?")[0],
                    "content_type": self.headers.get("Content-Type", ""),
                    "bytes": len(body),
                    "mentions_kinhin": b"kinhin." in body,
                })
                self.reply(200, b"", "application/x-protobuf")

        ThreadingHTTPServer(("127.0.0.1", port), Handler).serve_forever()
        """#
}

extension E2E {
    /// Whether something accepts TCP connections on 127.0.0.1:`port` right now (a bound listener, not an HTTP answer).
    public static func isListening(port: Int) -> Bool {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = in_port_t(port).bigEndian
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        let result = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        return result == 0
    }
}
