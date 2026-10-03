import XCTest

@testable import KinhinKit
@testable import KinhinTestSupport

/// Daemon.handle dispatch for the methods the sibling wire/client suites do
/// not cover: start/stop, status, logs, and token-swap payload validation.
final class RPCDaemonDispatchTests: XCTestCase {
    private let testHost = HostResources(logicalCores: 12, memoryGB: 32, freeDiskGB: 200, arm64: true)

    private func makeEngine(github: FakeGitHub = FakeGitHub()) -> FleetEngine {
        FleetEngine(
            config: makeTestConfig(),
            github: github,
            tart: FakeTart(),
            store: makeTestStore(),
            ssh: FakeSSH(),
            host: testHost,
            // Hermetic: start() must not read the real Keychain.
            dependencies: .init(tokenLoader: { _, _ in "test-token" })
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
        Log.echoToStderr = false  // keep the marker out of test output
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
            RPCRequest(
                id: 16, method: .replaceGiteaToken,
                payload: try! JSONEncoder().encode(GiteaTokenReplaceRequest(token: "gt-new"))),
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
}
