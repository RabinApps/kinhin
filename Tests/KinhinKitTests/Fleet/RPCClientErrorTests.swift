import XCTest

@testable import KinhinKit
@testable import KinhinTestSupport

/// RPCClient error paths. These need real kernel sockets (connect/timeout
/// semantics), so they bind throwaway file sockets under /tmp; everything
/// in-memory lives in the sibling wire suite.
final class RPCClientErrorTests: XCTestCase {
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

    func testClientThrowsConnectionFailedWhenSocketMissing() {
        let missing = FileManager.default.temporaryDirectory
            .appendingPathComponent("kinhin-nope-\(UUID().uuidString).sock")
        XCTAssertFalse(FileManager.default.fileExists(atPath: missing.path))
        XCTAssertFalse(RPCClient.isDaemonAlive(socketURL: missing))

        XCTAssertThrowsError(try RPCClient(socketURL: missing).send(method: .ping)) { error in
            guard case RPCError.connectionFailed = error else {
                return XCTFail("expected connectionFailed, got \(error)")
            }
            XCTAssertTrue(
                error.localizedDescription.contains("kinhin daemon"), "message must hint at the fix: \(error)")
        }
    }

    func testClientThrowsSocketPathTooLong() throws {
        // sun_path holds 104 bytes; the client must refuse a longer path
        // instead of silently truncating the address.
        let long = FileManager.default.temporaryDirectory
            .appendingPathComponent(String(repeating: "d", count: 120) + ".sock")
        try Data().write(to: long)  // the existence check runs first
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
        XCTAssertTrue(try client.send(method: .ping).ok, "ping over a live server connection must succeed")
        close(listener)
    }

    func testRejectionMapsToUserFacingMessage() {
        // replaceToken / replaceAccountToken / reloadConfig map ok:false
        // responses to RPCError.rejected; the LocalizedError text is the
        // user-facing contract the CLI and app surface.
        let rejected = RPCError.rejected("keychain save failed")
        XCTAssertEqual(rejected.localizedDescription, "daemon rejected the request: keychain save failed")
        XCTAssertEqual(RPCError.timeout.localizedDescription, "daemon did not answer in time")
    }
}
