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
        /// Request headers, names lowercased.
        public let headers: [String: String]
        /// Printable runs (4+ characters) found in the decoded body: metric, span and attribute names and string values.
        /// Protobuf stores those as plain UTF-8, so this identifies what an export carries without a protobuf decoder.
        public let strings: Set<String>

        /// Whether the body carries `text` as a whole string or as part of one.
        public func has(_ text: String) -> Bool { strings.contains { $0.contains(text) } }
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
                bytes: $0["bytes"] as? Int ?? 0, mentionsKinhin: $0["mentions_kinhin"] as? Bool ?? false,
                headers: $0["headers"] as? [String: String] ?? [:],
                strings: Set(($0["strings"] as? [String]) ?? []))
        }
    }

    /// Whether any export to `path` carries `text` in a string.
    public func received(_ text: String, at path: String) async -> Bool {
        await requests(to: path).contains { $0.has(text) }
    }

    /// The requests posted to exactly `path` (for example `/v1/metrics`).
    public func requests(to path: String) async -> [Request] {
        await requests().filter { $0.path == path }
    }

    private static let script = #"""
        import gzip, json, re, sys
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
                    "headers": {k.lower(): v for k, v in self.headers.items()},
                    "strings": sorted(set(m.decode("latin-1") for m in re.findall(rb"[\x20-\x7e]{4,}", body)))[:2000],
                })
                self.reply(200, b"", "application/x-protobuf")

        ThreadingHTTPServer(("127.0.0.1", port), Handler).serve_forever()
        """#
}

/// A raw TCP listener that records whether a client opened with the HTTP/2 connection preface, which is how every gRPC
/// client starts. It proves the daemon dialed a gRPC endpoint without a gRPC server (Python's standard library has no HTTP/2).
public final class HTTP2PrefaceProbe: @unchecked Sendable {
    public let port: Int
    private let process = Process()
    private let directory: URL

    public init() async throws {
        guard FileManager.default.isExecutableFile(atPath: "/usr/bin/python3") else {
            throw E2EError.unavailable("python3 is needed for the gRPC probe (xcode-select --install)")
        }
        port = try E2E.freePort()
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("ke2e-h2-\(E2E.randomID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let script = directory.appendingPathComponent("probe.py")
        try Data(Self.script.utf8).write(to: script)
        process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        process.arguments = [script.path, String(port), directory.appendingPathComponent("seen").path]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        let port = self.port
        try await eventually("the gRPC probe to listen", timeout: 20, interval: 0.2) {
            E2E.isListening(port: port) ? true : nil as Bool?
        }
    }

    public func stop() {
        if process.isRunning { process.terminate() }
        try? FileManager.default.removeItem(at: directory)
    }

    /// Whether a client has sent the HTTP/2 preface (`PRI * HTTP/2.0`) to the probe.
    public var sawHTTP2Preface: Bool {
        FileManager.default.fileExists(atPath: directory.appendingPathComponent("seen").path)
    }

    private static let script = #"""
        import socket, sys, threading

        port, marker = int(sys.argv[1]), sys.argv[2]
        server = socket.socket()
        server.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        server.bind(("127.0.0.1", port))
        server.listen(8)

        def handle(conn):
            try:
                if conn.recv(24).startswith(b"PRI * HTTP/2.0"):
                    open(marker, "w").write("h2")
            except Exception:
                pass
            finally:
                conn.close()

        while True:
            conn, _ = server.accept()
            threading.Thread(target=handle, args=(conn,), daemon=True).start()
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
