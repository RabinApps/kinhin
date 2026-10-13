import Foundation

/// A local stand-in for the music library (Openverse), so the music tests need no network and never touch the public service.
/// It answers `/v1/audio/` searches (honoring `license=` and `page=`), `/v1/audio/<id>/` and serves the audio files. A debug
/// `kinhin` is pointed at it with `KINHIN_OPENVERSE_URL`. It runs as a small Python server (python3 ships with the Xcode tools).
public final class MusicLibraryStub: @unchecked Sendable {
    public enum Mode: String, Sendable {
        /// Answers searches and serves files.
        case normal
        /// Answers every search with 429.
        case rateLimited = "rate-limited"
    }

    public struct Item: Sendable {
        public let id: String
        public let title: String
        public let license: String
        public let seconds: Int
    }

    /// What the stub offers: two reusable tracks, one that needs credit, and one that is not reusable at all.
    public static let items: [Item] = [
        Item(id: "11111111-1111-4111-8111-111111111111", title: "Lofi Test Loop", license: "cc0", seconds: 40),
        Item(id: "22222222-2222-4222-8222-222222222222", title: "Calm Piano Test", license: "cc0", seconds: 35),
        Item(id: "33333333-3333-4333-8333-333333333333", title: "Credit Required Test", license: "by", seconds: 50),
        Item(id: "44444444-4444-4444-8444-444444444444", title: "Non Commercial Test", license: "by-nc", seconds: 45),
    ]

    public let port: Int
    public var endpoint: String { "http://127.0.0.1:\(port)/v1/audio/" }
    private let process = Process()
    private let scriptURL: URL

    /// Starts the server and waits until it answers. `audio` is what every file download returns.
    public init(mode: Mode = .normal, audio: Data) async throws {
        guard FileManager.default.isExecutableFile(atPath: "/usr/bin/python3") else {
            throw E2EError.unavailable("python3 is needed for the music library stand-in (xcode-select --install)")
        }
        port = try E2E.freePort()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("ke2e-music-\(E2E.randomID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        scriptURL = directory.appendingPathComponent("server.py")
        let audioURL = directory.appendingPathComponent("audio.bin")
        try audio.write(to: audioURL)
        let table = try JSONSerialization.data(
            withJSONObject: Self.items.map {
                ["id": $0.id, "title": $0.title, "license": $0.license, "seconds": $0.seconds]
            })
        try Data(Self.script.utf8).write(to: scriptURL)
        try table.write(to: directory.appendingPathComponent("items.json"))

        process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        process.arguments = [
            scriptURL.path, String(port), mode.rawValue, audioURL.path,
            directory.appendingPathComponent("items.json").path,
        ]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        try await eventually("the music library stand-in to answer", timeout: 20, interval: 0.2) {
            let response = try? await Http.request("GET", "http://127.0.0.1:\(self.port)/health", timeout: 2)
            return response?.ok == true ? true : nil as Bool?
        }
    }

    public func stop() {
        if process.isRunning { process.terminate() }
        try? FileManager.default.removeItem(at: scriptURL.deletingLastPathComponent())
    }

    private static let script = #"""
        import json, sys
        from http.server import BaseHTTPRequestHandler, HTTPServer
        from urllib.parse import urlparse, parse_qs

        port, mode, audio_path, items_path = int(sys.argv[1]), sys.argv[2], sys.argv[3], sys.argv[4]
        items = json.load(open(items_path))
        audio = open(audio_path, "rb").read()

        def result(item):
            return {
                "id": item["id"], "title": item["title"], "creator": "e2e", "license": item["license"],
                "license_version": "1.0", "license_url": "https://creativecommons.org/licenses/" + item["license"] + "/1.0/",
                "source": "e2e", "foreign_landing_url": "http://127.0.0.1:%d/landing/%s" % (port, item["id"]),
                "url": "http://127.0.0.1:%d/files/%s.mp3" % (port, item["id"]), "filetype": "mp3",
                "duration": item["seconds"] * 1000, "filesize": len(audio), "mature": False,
            }

        class Handler(BaseHTTPRequestHandler):
            def log_message(self, *args): pass

            def send(self, status, body, kind="application/json", headers=None):
                self.send_response(status)
                self.send_header("Content-Type", kind)
                self.send_header("Content-Length", str(len(body)))
                for k, v in (headers or {}).items(): self.send_header(k, v)
                self.end_headers()
                self.wfile.write(body)

            def do_GET(self):
                url = urlparse(self.path)
                query = parse_qs(url.query)
                if url.path == "/health":
                    return self.send(200, b"ok", "text/plain")
                if url.path.startswith("/files/"):
                    return self.send(200, audio, "audio/mpeg")
                if url.path == "/v1/audio/":
                    if mode == "rate-limited":
                        return self.send(429, b'{"detail":"rate limited"}', headers={"Retry-After": "7"})
                    licenses = [l for v in query.get("license", [""]) for l in v.split(",")]
                    words = query.get("q", [""])[0].lower().split()
                    page = int(query.get("page", ["1"])[0])
                    found = [] if page != 1 else [
                        result(i) for i in items
                        if (not licenses or i["license"] in licenses) and all(w in i["title"].lower() for w in words)
                    ]
                    return self.send(200, json.dumps({"result_count": len(found), "results": found}).encode())
                if url.path.startswith("/v1/audio/"):
                    wanted = url.path.strip("/").split("/")[-1]
                    for i in items:
                        if i["id"] == wanted: return self.send(200, json.dumps(result(i)).encode())
                return self.send(404, b'{"detail":"not found"}')

        HTTPServer(("127.0.0.1", port), Handler).serve_forever()
        """#
}
