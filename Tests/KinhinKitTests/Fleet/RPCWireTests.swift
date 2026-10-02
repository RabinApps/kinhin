import XCTest

@testable import KinhinKit
@testable import KinhinTestSupport

/// The Fleet RPC wire layer: codec edge cases and request/response framing
/// over in-memory socketpairs (no listener, no filesystem), matching the
/// wire bytes the real unix-socket server would carry. Daemon dispatch and
/// client error paths live in the sibling suites.
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
        case .pipelineDetail: return "pipeline_detail"
        case .pipelineLog: return "pipeline_log"
        case .replaceToken: return "replace_token"
        case .replaceGiteaToken: return "replace_gitea_token"
        case .replaceForgejoToken: return "replace_forgejo_token"
        case .replaceAccountToken: return "replace_account_token"
        case .reloadConfig: return "reload_config"
        case .logs: return "logs"
        case .ping: return "ping"
        }
    }

    func testMethodRawValuesAreTheWireNames() {
        // The daemon and old CLI binaries must agree on these strings forever.
        for method in [
            RPCMethod.status, .start, .stop, .pause, .resume,
            .deleteVM, .pipelineDetail, .pipelineLog, .replaceToken, .replaceGiteaToken, .replaceAccountToken,
            .reloadConfig, .logs, .ping,
        ] {
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
        let request = try JSONDecoder().decode(
            RPCRequest.self, from: Data(#"{"id": 5, "method": "ping", "payload": null}"#.utf8))
        XCTAssertNil(request.payload)
    }

    func testRequestPayloadPreservesArbitraryBytes() throws {
        // Payload is an opaque Data blob end to end — including bytes that
        // are not valid UTF-8 (a malformed downstream payload must survive
        // the transport trip for the daemon's error path to report it).
        let raw: [UInt8] = [0x7B, 0xFF, 0xFE, 0x7D]  // {, invalid, invalid, }
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
        // The detached thread only needs the server end; copying it out of
        // the mutable array keeps the later capture var-free.
        let server = fds[1]
        let client = fds[0]
        defer { close(client) }

        // Serve on a detached thread (mirrors the daemon's worker queue) so
        // the test thread can write concurrently — a large request line
        // would otherwise block forever on the kernel's socket buffer.
        Thread.detachNewThread {
            RPCServer.handleConnection(fd: server, handler: handler)
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
        let response = decode(
            serveOne(requestLine: line("this is not json {{{")) { _ in
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
        let response = decode(
            serveOne(requestLine: line(#"[1, 2, 3]"#)) { _ in
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
        let bytes = reader.availableData  // blocks until server closes → EOF
        XCTAssertTrue(bytes.isEmpty, "an empty connection must produce no response bytes")
    }

    func testOversizedRequestLineIsDropped() {
        // readLine's sanity cap (1 MB) must discard absurd frames instead of
        // buffering forever: an over-cap line gets no response at all.
        let huge =
            line(#"{"id":1,"method":"ping","payload":"#)
            + Data(repeating: 0x61, count: 1_200_000)
            + Data("\"}".utf8)
        let response = decode(
            serveOne(requestLine: huge) { _ in
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
        let response = decode(
            serveOne(requestLine: line(json)) { request in
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
        try? writer.write(contentsOf: Data(#"{"id":3,"method":"ping"}"#.utf8))  // no 0x0A
        shutdown(client, Int32(SHUT_WR))  // EOF on the server's read side

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

    func testSlowHandlerGetsOneTimeoutReplyAndNothingAfterClose() async throws {
        // A handler that outlives the timeout: the client gets exactly one
        // timeout reply, then EOF. The late handler result must not be
        // written — the descriptor is closed and may belong to someone else.
        var fds: [Int32] = [0, 0]
        XCTAssertEqual(socketpair(AF_UNIX, SOCK_STREAM, 0, &fds), 0)
        let client = fds[0]
        defer { close(client) }
        let writer = FileHandle(fileDescriptor: client, closeOnDealloc: false)
        try writer.write(contentsOf: line(#"{"id":7,"method":"stop"}"#))

        let handlerFinished = expectation(description: "slow handler ran to completion")
        RPCServer.handleConnection(fd: fds[1], timeout: .milliseconds(50)) { request in
            try? await Task.sleep(for: .milliseconds(400))  // outlive the timeout; cancellation is not expected
            handlerFinished.fulfill()
            return RPCResponse(id: request.id, ok: true)
        }

        let reader = FileHandle(fileDescriptor: client, closeOnDealloc: false)
        var bytes = Data()
        while true {
            let chunk = reader.availableData  // blocks until data or EOF
            if chunk.isEmpty { break }
            bytes.append(chunk)
        }
        let response = decode(bytes)
        XCTAssertEqual(response?.id, 7)
        XCTAssertEqual(response?.ok, false)
        XCTAssertEqual(response?.error, "daemon timed out handling stop")

        await fulfillment(of: [handlerFinished], timeout: 5)
        XCTAssertEqual(bytes.filter { $0 == 0x0A }.count, 1, "exactly one reply frame before close")
    }

    func testFastHandlerAnswersAndCancelsTheTimeout() {
        let response = decode(
            serveOne(requestLine: line(#"{"id":8,"method":"ping"}"#)) { request in
                RPCResponse(id: request.id, ok: true)
            })
        XCTAssertEqual(response?.id, 8)
        XCTAssertEqual(response?.ok, true)
    }

    func testConnectionReplyAnswersOnlyOnce() {
        var fds: [Int32] = [0, 0]
        XCTAssertEqual(socketpair(AF_UNIX, SOCK_STREAM, 0, &fds), 0)
        defer { close(fds[0]) }
        let reply = ConnectionReply(fd: fds[1])
        XCTAssertTrue(reply.send(RPCResponse(id: 1, ok: true)))
        XCTAssertFalse(reply.send(RPCResponse(id: 2, ok: true)), "a second answer must be refused")
        reply.close()  // no-op after the first answer; must not double-close
    }
}
