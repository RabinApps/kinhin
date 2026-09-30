import XCTest

@testable import KinhinKit
@testable import KinhinTestSupport

final class RPCFramingTests: XCTestCase {
    func testRequestResponseFramingOverSocketpair() async throws {
        var fds: [Int32] = [0, 0]
        let rc = socketpair(AF_UNIX, SOCK_STREAM, 0, &fds)
        XCTAssertEqual(rc, 0, "socketpair must succeed")
        // handleConnection closes its own fd (fds[1]) on return; only close ours.
        defer { close(fds[0]) }

        // Write a request line to one end.
        let request = RPCRequest(id: 7, method: .ping)
        var line = try JSONEncoder().encode(request)
        line.append(0x0A)
        let writer = FileHandle(fileDescriptor: fds[0], closeOnDealloc: false)
        try writer.write(contentsOf: line)

        // Serve it on the other end (blocking, returns after responding).
        RPCServer.handleConnection(fd: fds[1]) { req in
            RPCResponse(id: req.id, ok: true, payload: try! JSONEncoder().encode(["pong": true]))
        }

        // Read the framed response back.
        let reader = FileHandle(fileDescriptor: fds[0], closeOnDealloc: false)
        var buffer = Data()
        while buffer.last != 0x0A {
            let chunk = reader.availableData
            if chunk.isEmpty { break }
            buffer.append(chunk)
        }
        let response = try JSONDecoder().decode(RPCResponse.self, from: buffer)
        XCTAssertEqual(response.id, 7)
        XCTAssertTrue(response.ok)
        let pong = try JSONDecoder().decode([String: Bool].self, from: XCTUnwrap(response.payload))
        XCTAssertEqual(pong["pong"], true)
    }

    /// A client that connects and never sends a line is dropped after the
    /// read timeout instead of holding its connection thread forever.
    func testSilentClientIsDroppedAfterTheReadTimeout() throws {
        var fds: [Int32] = [0, 0]
        XCTAssertEqual(socketpair(AF_UNIX, SOCK_STREAM, 0, &fds), 0)
        defer { close(fds[0]) }

        let started = Date()
        RPCServer.handleConnection(fd: fds[1], readTimeout: 0.2) { request in
            XCTFail("no request was sent")
            return RPCResponse(id: request.id, ok: true)
        }
        XCTAssertLessThan(Date().timeIntervalSince(started), 3, "the read must give up at its deadline")
        var byte: UInt8 = 0
        XCTAssertEqual(read(fds[0], &byte, 1), 0, "the server closes the silent connection")
    }

    /// `perform` runs the blocking socket call off the caller's thread, so
    /// the app's main actor never waits on a wedged daemon.
    @MainActor
    func testPerformRunsOffTheMainThread() async throws {
        let client = RPCClient(socketURL: URL(fileURLWithPath: "/nonexistent/kinhin.sock"))
        let onMain = try await client.perform { _ in Thread.isMainThread }
        XCTAssertFalse(onMain)
        do {
            try await client.perform { try $0.command(.ping) }
            XCTFail("a missing socket must throw through perform")
        } catch let error as RPCError {
            guard case .connectionFailed = error else { return XCTFail("\(error)") }
        }
    }

    func testResponseLineIsNewlineFramedJSON() throws {
        let data = RPCServer.responseLine(RPCResponse(id: 9, ok: false, error: "boom"))
        XCTAssertEqual(data.last, 0x0A)
        let decoded = try JSONDecoder().decode(RPCResponse.self, from: data.dropLast())
        XCTAssertEqual(decoded.error, "boom")
        XCTAssertFalse(decoded.ok)
    }
}
