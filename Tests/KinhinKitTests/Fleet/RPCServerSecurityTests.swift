import XCTest

@testable import KinhinKit
@testable import KinhinTestSupport

final class RPCServerSecurityTests: XCTestCase {
    func testSocketPairPeerIsTheCurrentUser() {
        var fds: [Int32] = [0, 0]
        XCTAssertEqual(socketpair(AF_UNIX, SOCK_STREAM, 0, &fds), 0)
        defer { fds.forEach { close($0) } }
        XCTAssertTrue(RPCServer.peerIsCurrentUser(fds[0]))
        XCTAssertFalse(RPCServer.peerIsCurrentUser(-1), "an invalid descriptor is never trusted")
    }

    func testLimiterRefusesPastTheMaximumAndRecoversOnRelease() {
        let limiter = ConnectionLimiter(maximum: 2)
        XCTAssertTrue(limiter.tryAcquire())
        XCTAssertTrue(limiter.tryAcquire())
        XCTAssertFalse(limiter.tryAcquire())
        limiter.release()
        XCTAssertTrue(limiter.tryAcquire())
        limiter.release()
        limiter.release()
        limiter.release()  // extra releases never drive the count negative
        XCTAssertTrue(limiter.tryAcquire())
        XCTAssertTrue(limiter.tryAcquire())
        XCTAssertFalse(limiter.tryAcquire())
    }

    func testReplyReleasesItsSlotExactlyOnce() {
        var fds: [Int32] = [0, 0]
        XCTAssertEqual(socketpair(AF_UNIX, SOCK_STREAM, 0, &fds), 0)
        defer { close(fds[0]) }
        let limiter = ConnectionLimiter(maximum: 1)
        XCTAssertTrue(limiter.tryAcquire())
        let reply = ConnectionReply(fd: fds[1], onClose: { limiter.release() })
        reply.close()
        reply.close()  // a second close must not release a second slot
        XCTAssertTrue(limiter.tryAcquire())
        XCTAssertFalse(limiter.tryAcquire())
    }

    func testServeRestrictsSocketAndDirectoryToTheOwner() async throws {
        // Short path: sun_path holds 104 bytes.
        let dir = URL(fileURLWithPath: "/tmp/kn-\(UInt32.random(in: 0..<UInt32.max))")
        defer { try? FileManager.default.removeItem(at: dir) }
        let socket = dir.appendingPathComponent("d.sock")
        let server = Task { try await RPCServer.serve(socketURL: socket) { RPCResponse(id: $0.id, ok: true) } }
        defer { server.cancel() }

        var waited = 0
        while !FileManager.default.fileExists(atPath: socket.path), waited < 100 {
            try await Task.sleep(for: .milliseconds(50))
            waited += 1
        }
        let socketMode = try XCTUnwrap(
            FileManager.default.attributesOfItem(atPath: socket.path)[.posixPermissions] as? Int)
        let dirMode = try XCTUnwrap(FileManager.default.attributesOfItem(atPath: dir.path)[.posixPermissions] as? Int)
        XCTAssertEqual(socketMode & 0o777, 0o600)
        XCTAssertEqual(dirMode & 0o777, 0o700)
    }
}
