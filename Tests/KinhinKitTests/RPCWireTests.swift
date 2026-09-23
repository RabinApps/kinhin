import XCTest
@testable import KinhinKit

/// The Fleet RPC wire layer: codec edge cases, Daemon dispatch for the
/// methods not covered by the sibling suites, and client error paths.
///
/// Transport is in-memory wherever possible: request/response framing runs
/// over socketpairs (no listener, no filesystem), matching the wire bytes the
/// real unix-socket server would carry. Only the client error-path tests bind
/// a throwaway file socket, because connect/timeout semantics need a real
/// kernel socket.
final class RPCWireTests: XCTestCase {
    override func setUp() {
        super.setUp()
        // The daemon masks SIGPIPE in serve(); tests that provoke
        // write-after-close (the oversized-line drop) need the same guard,
        // otherwise the default disposition kills the xctest process.
        signal(SIGPIPE, SIG_IGN)
    }

    // MARK: - Codec edge cases

    /// Compiler-forced exhaustiveness: adding an RPCMethod without wiring it
    /// into the wire-name table fails to compile.
    private func wireName(_ method: RPCMethod) -> String {
        switch method {
        case .status: return "status"
        case .start: return "start"
        case .stop: return "stop"
        case .pause: return "pause"
        case .resume: return "resume"
        case .deleteVM: return "delete_vm"
        case .replaceToken: return "replace_token"
        case .replaceGiteaToken: return "replace_gitea_token"
        case .reloadConfig: return "reload_config"
        case .logs: return "logs"
        case .ping: return "ping"
        }
    }

    func testMethodRawValuesAreTheWireNames() {
        // The daemon and old CLI binaries must agree on these strings forever.
        for method in [RPCMethod.status, .start, .stop, .pause, .resume,
                       .deleteVM, .replaceToken, .replaceGiteaToken,
                       .reloadConfig, .logs, .ping] {
            XCTAssertEqual(method.rawValue, wireName(method), "\(method) must keep its wire name")
        }
        XCTAssertEqual(wireName(.ping), "ping")
    }

    func testUnknownMethodDoesNotDecode() throws {
        // Forward-compatibility contract: an unknown method must fail decode
        // (so the server answers "undecodable request"), never crash.
        let json = #"{"id": 3, "method": "teleport_vm"}"#
        XCTAssertThrowsError(try JSONDecoder().decode(RPCRequest.self, from: Data(json.utf8)))
    }

    func testPayloadOmittedDecodesAsNil() throws {
        let request = try JSONDecoder().decode(RPCRequest.self, from: Data(#"{"id": 4, "method": "status"}"#.utf8))
        XCTAssertEqual(request.method, .status)
        XCTAssertNil(request.payload)
    }

    func testNullPayloadDecodesAsNil() throws {
        let request = try JSONDecoder().decode(RPCRequest.self, from: Data(#"{"id": 5, "method": "ping", "payload": null}"#.utf8))
        XCTAssertNil(request.payload)
    }

    func testRequestPayloadPreservesArbitraryBytes() throws {
        // Payload is an opaque Data blob end to end — including bytes that
        // are not valid UTF-8 (a malformed downstream payload must survive
        // the transport trip for the daemon's error path to report it).
        let raw: [UInt8] = [0x7B, 0xFF, 0xFE, 0x7D] // {, invalid, invalid, }
        let request = RPCRequest(id: 6, method: .deleteVM, payload: Data(raw))
        let roundTrip = try JSONDecoder().decode(RPCRequest.self, from: JSONEncoder().encode(request))
        XCTAssertEqual(roundTrip, request)
        XCTAssertEqual(Array(roundTrip.payload!), raw)
    }

    func testUnicodeSurvivesRequestAndResponseEncoding() throws {
        let request = RPCRequest(id: 7, method: .replaceToken, payload: Data("{\"pat\":\"ключ-🔑\"}".utf8))
        let roundTrip = try JSONDecoder().decode(RPCRequest.self, from: JSONEncoder().encode(request))
        XCTAssertEqual(roundTrip, request)

        let response = RPCResponse(id: 8, ok: false, error: "не найдено — 🔥")
        let responseLine = RPCServer.responseLine(response)
        XCTAssertEqual(responseLine.last, 0x0A, "responses are newline-framed")
        let decoded = try JSONDecoder().decode(RPCResponse.self, from: responseLine.dropLast())
        XCTAssertEqual(decoded.error, "не найдено — 🔥")
    }

    func testResponseLineIsAlwaysNewlineFramed() {
        // Encoding cannot fail for any representable RPCResponse, but the
        // guard is there — pin the shape of the fallback frame too.
        for response in [RPCResponse(id: 9, ok: true), RPCResponse(id: 10, ok: false, error: "boom")] {
            let line = RPCServer.responseLine(response)
            XCTAssertEqual(line.last, 0x0A)
            let decoded = try! JSONDecoder().decode(RPCResponse.self, from: line.dropLast())
            XCTAssertEqual(decoded.id, response.id)
            XCTAssertEqual(decoded.ok, response.ok)
        }
    }

    // MARK: - Framing over in-memory socketpair

    /// Serves one connection over a socketpair and returns the client-side
    /// response bytes, exercising the real readLine/responseLine path with no
    /// listener socket or filesystem.
    private func serveOne(
        requestLine: Data,
        handler: @escaping @Sendable (RPCRequest) async -> RPCResponse
    ) -> Data? {
        var fds: [Int32] = [0, 0]
        guard socketpair(AF_UNIX, SOCK_STREAM, 0, &fds) == 0 else {
            XCTFail("socketpair must succeed")
            return nil
        }
        let client = fds[0]
        defer { close(client) }

        // Serve on a detached thread (mirrors the daemon's worker queue) so
        // the test thread can write concurrently — a large request line
        // would otherwise block forever on the kernel's socket buffer.
        Thread.detachNewThread {
            RPCServer.handleConnection(fd: fds[1], handler: handler)
        }

        if !requestLine.isEmpty {
            let writer = FileHandle(fileDescriptor: client, closeOnDealloc: false)
            try? writer.write(contentsOf: requestLine)
        }

        // Drain the response from the client end.
        let reader = FileHandle(fileDescriptor: client, closeOnDealloc: false)
        var buffer = Data()
        while buffer.last != 0x0A {
            let chunk = reader.availableData
            if chunk.isEmpty { break }
            buffer.append(chunk)
        }
        return buffer.isEmpty ? nil : buffer
    }

    private func line(_ json: String) -> Data {
        var data = Data(json.utf8)
        data.append(0x0A)
        return data
    }

    private func decode(_ data: Data?) -> RPCResponse? {
        guard let data, data.last == 0x0A else { return nil }
        return try? JSONDecoder().decode(RPCResponse.self, from: data.dropLast())
    }

    func testGarbageRequestGetsUndecodableErrorResponse() {
        let response = decode(serveOne(requestLine: line("this is not json {{{")) { _ in
            RPCResponse(id: 0, ok: true)
        })
        XCTAssertNotNil(response)
        XCTAssertFalse(response!.ok)
        XCTAssertEqual(response!.error, "undecodable request")
        XCTAssertEqual(response!.id, -1, "no request id exists to echo")
    }

    func testValidJSONWithWrongShapeGetsUndecodableErrorResponse() {
        // Parseable JSON that isn't an RPCRequest must take the same error
        // path, not crash the connection handler.
        let response = decode(serveOne(requestLine: line(#"[1, 2, 3]"#)) { _ in
            RPCResponse(id: 0, ok: true)
        })
        XCTAssertEqual(response?.error, "undecodable request")
    }

    func testEmptyConnectionClosesWithoutResponse() {
        // Connect and immediately send EOF: the server must not write a
        // response or hang — handleConnection returns and closes.
        var fds: [Int32] = [0, 0]
        XCTAssertEqual(socketpair(AF_UNIX, SOCK_STREAM, 0, &fds), 0)
        let client = fds[0]
        defer { close(client) }

        // EOF before serving: the server's read must end immediately.
        shutdown(client, Int32(SHUT_WR))

        RPCServer.handleConnection(fd: fds[1]) { _ in
            XCTFail("no request should reach the handler")
            return RPCResponse(id: 0, ok: true)
        }
        let reader = FileHandle(fileDescriptor: client, closeOnDealloc: false)
        let bytes = reader.availableData // blocks until server closes → EOF
        XCTAssertTrue(bytes.isEmpty, "an empty connection must produce no response bytes")
    }

    func testOversizedRequestLineIsDropped() {
        // readLine's sanity cap (1 MB) must discard absurd frames instead of
        // buffering forever: an over-cap line gets no response at all.
        let huge = line(#"{"id":1,"method":"ping","payload":"#)
            + Data(repeating: 0x61, count: 1_200_000)
            + Data("\"}".utf8)
        let response = decode(serveOne(requestLine: huge) { _ in
            XCTFail("an over-cap line must never be dispatched")
            return RPCResponse(id: 1, ok: true)
        })
        XCTAssertNil(response, "an over-cap line must be dropped, not answered")
    }

    func testOversizeCapAcceptsLargeButLegalLines() {
        // The cap is abuse protection, not a payload limit: a big-but-legal
        // request (well under 1 MB) must still be answered.
        let filler = String(repeating: "a", count: 400_000)
        let json = #"{"id":2,"method":"ping","payload":"# + "\"\(filler)\"}"
        let response = decode(serveOne(requestLine: line(json)) { request in
            RPCResponse(id: request.id, ok: true)
        })
        XCTAssertEqual(response?.ok, true)
        XCTAssertEqual(response?.id, 2)
    }

    func testEOFFlushesAnUnterminatedFrame() {
        // Framing contract: a trailing newline is the normal terminator, but
        // EOF also flushes the buffered bytes — so a request whose writer
        // died mid-frame is still dispatched rather than dropped.
        var fds: [Int32] = [0, 0]
        XCTAssertEqual(socketpair(AF_UNIX, SOCK_STREAM, 0, &fds), 0)
        let client = fds[0]
        defer { close(client) }

        let writer = FileHandle(fileDescriptor: client, closeOnDealloc: false)
        try? writer.write(contentsOf: Data(#"{"id":3,"method":"ping"}"#.utf8)) // no 0x0A
        shutdown(client, Int32(SHUT_WR)) // EOF on the server's read side

        RPCServer.handleConnection(fd: fds[1]) { request in
            XCTAssertEqual(request.id, 3)
            XCTAssertEqual(request.method, .ping)
            return RPCResponse(id: request.id, ok: true)
        }
        let reader = FileHandle(fileDescriptor: client, closeOnDealloc: false)
        let bytes = reader.availableData
        let response = try? JSONDecoder().decode(RPCResponse.self, from: bytes.dropLast())
        XCTAssertEqual(response?.ok, true, "EOF must flush the buffered frame and dispatch it")
        XCTAssertEqual(response?.id, 3)
    }

    // MARK: - Daemon dispatch: methods not covered by sibling suites

    private func makeEngine(github: FakeGitHub = FakeGitHub()) -> FleetEngine {
        FleetEngine(
            config: makeTestConfig(),
            github: github,
            tart: FakeTart(),
            store: makeTestStore(),
            ssh: FakeSSH(),
            host: testHost
        )
    }

    func testDaemonStartRunsAndStopHaltsTheEngine() async throws {
        let engine = makeEngine()

        let start = await Daemon.handle(RPCRequest(id: 10, method: .start), engine: engine)
        XCTAssertTrue(start.ok)
        try await waitUntil(timeout: 5) {
            let status = await engine.status()
            return status.running
        }

        let stop = await Daemon.handle(RPCRequest(id: 11, method: .stop), engine: engine)
        XCTAssertTrue(stop.ok)
        try await waitUntil(timeout: 5) {
            let status = await engine.status()
            return !status.running
        }
    }

    func testDaemonStartAnswersOkEvenWhenPermissionBlocked() async {
        // An org PAT without runner rights blocks startup: the RPC itself
        // still answers ok (the request succeeded); the failure surfaces in
        // status.lastError, which the CLI/app render.
        let github = FakeGitHub()
        github.permissionDenied = true
        let engine = makeEngine(github: github)

        let start = await Daemon.handle(RPCRequest(id: 12, method: .start), engine: engine)
        XCTAssertTrue(start.ok)

        let statusResponse = await Daemon.handle(RPCRequest(id: 13, method: .status), engine: engine)
        let fleet = try? JSONDecoder().decode(FleetStatus.self, from: statusResponse.payload ?? Data())
        XCTAssertNotNil(fleet)
        XCTAssertFalse(fleet!.running)
        XCTAssertNotNil(fleet!.lastError, "blocked startup must be visible in status")
    }

    func testDaemonLogsReturnsDecodableSnapshot() async {
        let previousEcho = Log.echoToStderr
        Log.echoToStderr = false // keep the marker out of test output
        defer { Log.echoToStderr = previousEcho }
        let marker = "rpc-logs-\(UUID().uuidString)"
        Log.info("rpc-test", marker)

        let engine = makeEngine()
        let response = await Daemon.handle(RPCRequest(id: 14, method: .logs), engine: engine)
        XCTAssertTrue(response.ok)

        let entries = try? JSONDecoder().decode([Log.Entry].self, from: response.payload ?? Data())
        XCTAssertNotNil(entries)
        XCTAssertFalse(entries!.isEmpty, "the snapshot just logged an entry")
        XCTAssertTrue(entries!.contains { $0.message == marker && $0.component == "rpc-test" })
    }

    func testDaemonReplaceGiteaTokenValidatesPayloadShape() async {
        // The engine here declares no gitea forge, so a valid swap is a
        // logged no-op; what this pins is the payload contract: a malformed
        // body is rejected with the expected shape spelled out, a well-formed
        // one is accepted.
        let engine = makeEngine()

        let bad = await Daemon.handle(
            RPCRequest(id: 15, method: .replaceGiteaToken, payload: try! JSONEncoder().encode(["nope": 1])),
            engine: engine
        )
        XCTAssertFalse(bad.ok)
        XCTAssertEqual(bad.id, 15)
        XCTAssertTrue(bad.error?.contains("token") ?? false, "error should name the expected shape: \(bad.error ?? "")")

        let good = await Daemon.handle(
            RPCRequest(id: 16, method: .replaceGiteaToken, payload: try! JSONEncoder().encode(GiteaTokenReplaceRequest(token: "gt-new"))),
            engine: engine
        )
        XCTAssertTrue(good.ok, "a well-formed swap must be accepted: \(good.error ?? "")")
    }

    func testDaemonEchoesRequestIDOnEveryResponse() async {
        // Responses carry the caller's id so the one-request-per-connection
        // client can match them — including rejections.
        for id in [1, 999_999] {
            let pong = await Daemon.handle(RPCRequest(id: id, method: .ping), engine: makeEngine())
            XCTAssertEqual(pong.id, id)
            XCTAssertTrue(pong.ok)
        }
        let rejected = await Daemon.handle(
            RPCRequest(id: 42, method: .deleteVM, payload: Data("{}".utf8)),
            engine: makeEngine()
        )
        XCTAssertEqual(rejected.id, 42)
        XCTAssertFalse(rejected.ok)
    }

    // MARK: - Client error paths

    /// Short throwaway socket path: sun_path caps at 104 bytes and the
    /// per-user temp directory is already close to that, so file-socket
    /// tests bind under /tmp instead.
    private func scratchSocket(_ name: String) -> URL {
        let url = URL(fileURLWithPath: "/tmp/kinhin-rpc-\(UUID().uuidString.prefix(8))-\(name).sock")
        try? FileManager.default.removeItem(at: url)
        return url
    }

    private func bindListener(at socketURL: URL) -> Int32 {
        let listener = socket(AF_UNIX, SOCK_STREAM, 0)
        XCTAssertGreaterThanOrEqual(listener, 0)
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutableBytes(of: &addr.sun_path) { $0.copyBytes(from: Array(socketURL.path.utf8)) }
        let bound = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                Darwin.bind(listener, sa, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        XCTAssertEqual(bound, 0, "test socket must bind: \(socketURL.path)")
        return listener
    }

    /// Engine state flips asynchronously (start verification runs in a
    /// detached task), so observe it the way the sibling suites do: poll.
    private func waitUntil(timeout: TimeInterval, _ condition: () async -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if await condition() { return }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        XCTFail("condition not met within \(timeout)s")
    }

    func testClientThrowsConnectionFailedWhenSocketMissing() {
        let missing = FileManager.default.temporaryDirectory
            .appendingPathComponent("kinhin-nope-\(UUID().uuidString).sock")
        XCTAssertFalse(FileManager.default.fileExists(atPath: missing.path))
        XCTAssertFalse(RPCClient.isDaemonAlive(socketURL: missing))

        XCTAssertThrowsError(try RPCClient(socketURL: missing).send(method: .ping)) { error in
            guard case RPCError.connectionFailed = error else {
                return XCTFail("expected connectionFailed, got \(error)")
            }
            XCTAssertTrue(error.localizedDescription.contains("kinhin daemon"), "message must hint at the fix: \(error)")
        }
    }

    func testClientThrowsSocketPathTooLong() throws {
        // sun_path holds 104 bytes; the client must refuse a longer path
        // instead of silently truncating the address.
        let long = FileManager.default.temporaryDirectory
            .appendingPathComponent(String(repeating: "d", count: 120) + ".sock")
        try Data().write(to: long) // the existence check runs first
        defer { try? FileManager.default.removeItem(at: long) }

        XCTAssertThrowsError(try RPCClient(socketURL: long).send(method: .ping)) { error in
            guard case RPCError.socketPathTooLong = error else {
                return XCTFail("expected socketPathTooLong, got \(error)")
            }
        }
    }

    func testClientTimesOutWhenDaemonNeverAnswers() throws {
        // A listening socket nobody accepts on: connect completes (kernel
        // backlog), the request is written, and no response ever comes —
        // the closest a test can get to a hung daemon.
        let socketURL = scratchSocket("hung")
        defer { try? FileManager.default.removeItem(at: socketURL) }

        let listener = bindListener(at: socketURL)
        defer { close(listener) }
        XCTAssertEqual(listen(listener, 8), 0)
        // Deliberately never accept() — the daemon never answers.

        XCTAssertThrowsError(try RPCClient(socketURL: socketURL).send(method: .ping, timeout: 0.5)) { error in
            guard case RPCError.timeout = error else {
                return XCTFail("expected timeout, got \(error)")
            }
        }
        // (No isDaemonAlive check here: it pings at the default 60s timeout,
        // which would hang the suite against this deliberately dead socket.)
    }

    func testClientPingRoundTripsOverARealServerConnection() throws {
        // The one place a real socket is needed: isDaemonAlive → ping → send
        // over an actual bound, listening, accepting server connection.
        let socketURL = scratchSocket("alive")
        defer { try? FileManager.default.removeItem(at: socketURL) }

        let listener = bindListener(at: socketURL)
        XCTAssertEqual(listen(listener, 8), 0)

        // One accept, served by the real connection handler (no daemon proc).
        Thread.detachNewThread {
            var len = socklen_t(MemoryLayout<sockaddr_un>.size)
            var clientAddr = sockaddr_un()
            let fd = withUnsafeMutablePointer(to: &clientAddr) { ptr in
                ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                    accept(listener, sa, &len)
                }
            }
            guard fd >= 0 else { return }
            RPCServer.handleConnection(fd: fd) { request in
                RPCResponse(id: request.id, ok: true)
            }
        }

        let client = RPCClient(socketURL: socketURL)
        XCTAssertTrue(try client.ping(), "ping over a live server connection must succeed")
        close(listener)
    }

    func testRejectionMapsToUserFacingMessage() {
        // replaceToken / replaceGiteaToken / reloadConfig map ok:false
        // responses to RPCError.rejected; the LocalizedError text is the
        // user-facing contract the CLI and app surface.
        let rejected = RPCError.rejected("keychain save failed")
        XCTAssertEqual(rejected.localizedDescription, "daemon rejected the request: keychain save failed")
        XCTAssertEqual(RPCError.timeout.localizedDescription, "daemon did not answer in time")
    }
}
