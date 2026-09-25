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

    func testResponseLineIsNewlineFramedJSON() throws {
        let data = RPCServer.responseLine(RPCResponse(id: 9, ok: false, error: "boom"))
        XCTAssertEqual(data.last, 0x0A)
        let decoded = try JSONDecoder().decode(RPCResponse.self, from: data.dropLast())
        XCTAssertEqual(decoded.error, "boom")
        XCTAssertFalse(decoded.ok)
    }
}
