import Foundation

/// A local stand-in for an alert webhook (Slack, Discord, ntfy or a pager): it records the method, path, headers and
/// text body of every POST and answers with `status`. `GET /__requests` returns the record. Runs as a small Python
/// server like `OTLPCollectorStub`; nothing leaves the Mac.
public final class WebhookStub: @unchecked Sendable {
    public struct Request: Sendable {
        public let method: String
        public let path: String
        /// Request headers, names lowercased.
        public let headers: [String: String]
        public let body: String

        /// The body parsed as a JSON object, or nil when it is not one (ntfy sends plain text).
        public var json: [String: Any]? {
            (try? JSONSerialization.jsonObject(with: Data(body.utf8))) as? [String: Any]
        }
    }

    public let port: Int
    /// The URL to put in `alerts.webhook.url`.
    public var url: String { "http://127.0.0.1:\(port)/hook" }
    private let process = Process()
    private let directory: URL

    /// `status` is what the stub answers to every POST (500 stands in for a dead endpoint).
    public init(status: Int = 200) async throws {
        guard FileManager.default.isExecutableFile(atPath: "/usr/bin/python3") else {
            throw E2EError.unavailable("python3 is needed for the webhook stand-in (xcode-select --install)")
        }
        port = try E2E.freePort()
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("ke2e-hook-\(E2E.randomID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let script = directory.appendingPathComponent("server.py")
        try Data(Self.script.utf8).write(to: script)
        process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        process.arguments = [script.path, String(port), String(status)]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        let port = self.port
        try await eventually("the webhook stand-in to answer", timeout: 20, interval: 0.2) {
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
                method: $0["method"] as? String ?? "", path: $0["path"] as? String ?? "",
                headers: $0["headers"] as? [String: String] ?? [:], body: $0["body"] as? String ?? "")
        }
    }

    private static let script = #"""
        import json, sys
        from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

        port, status = int(sys.argv[1]), int(sys.argv[2])
        seen = []

        class Handler(BaseHTTPRequestHandler):
            def log_message(self, *args): pass

            def reply(self, code, body, kind):
                self.send_response(code)
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
                seen.append({
                    "method": "POST",
                    "path": self.path.split("?")[0],
                    "headers": {k.lower(): v for k, v in self.headers.items()},
                    "body": body.decode("utf-8", "replace"),
                })
                self.reply(status, b"ok", "text/plain")

        ThreadingHTTPServer(("127.0.0.1", port), Handler).serve_forever()
        """#
}
