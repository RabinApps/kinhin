import XCTest

@testable import KinhinKit
@testable import KinhinTestSupport

final class DaemonDispatchTests: XCTestCase {
    func makeEngine(tart: FakeTart, github: FakeGitHub, ssh: FakeSSH) -> FleetEngine {
        FleetEngine(
            config: makeTestConfig(),
            github: github,
            tart: tart,
            store: makeTestStore(),
            ssh: ssh,
            host: testHost
        )
    }

    func testDaemonPingAndStatus() async throws {
        let engine = makeEngine(tart: FakeTart(), github: FakeGitHub(), ssh: FakeSSH())
        let ping = await Daemon.handle(RPCRequest(id: 1, method: .ping), engine: engine)
        XCTAssertTrue(ping.ok)
        let pong = try JSONDecoder().decode(PingReply.self, from: XCTUnwrap(ping.payload))
        XCTAssertTrue(pong.pong)
        XCTAssertEqual(pong.protocolVersion, PingReply.currentProtocol)

        let status = await Daemon.handle(RPCRequest(id: 2, method: .status), engine: engine)
        XCTAssertTrue(status.ok)
        let fleet = try JSONDecoder().decode(FleetStatus.self, from: XCTUnwrap(status.payload))
        XCTAssertEqual(fleet.desired, 0)
        XCTAssertFalse(fleet.running)
    }

    func testDaemonDeleteVMRemovesRecordAndTartVM() async throws {
        let tart = FakeTart()
        let engine = makeEngine(tart: tart, github: FakeGitHub(), ssh: FakeSSH())
        engine.store.upsert(VMRecord(id: "kinhin-die", phase: .ready))
        tart.vms["kinhin-die"] = TartVM(name: "kinhin-die", source: "tahoe-base", status: "running")

        let payload = try JSONEncoder().encode(Daemon.VMDeleteRequest(id: "kinhin-die"))
        let response = await Daemon.handle(RPCRequest(id: 3, method: .deleteVM, payload: payload), engine: engine)
        XCTAssertTrue(response.ok)

        let status = await engine.status()
        XCTAssertTrue(status.records.isEmpty)
        XCTAssertTrue(tart.deleteCalls.contains("kinhin-die"))
    }

    func testDaemonDeleteVMBadPayloadIsRejected() async throws {
        let engine = makeEngine(tart: FakeTart(), github: FakeGitHub(), ssh: FakeSSH())
        let bad = try JSONEncoder().encode(["wrong": "shape"])
        let response = await Daemon.handle(RPCRequest(id: 4, method: .deleteVM, payload: bad), engine: engine)
        XCTAssertFalse(response.ok)
        XCTAssertTrue(response.error?.contains("expected") == true)
    }

    func testDaemonPauseResumeRoundTrip() async throws {
        let engine = makeEngine(tart: FakeTart(), github: FakeGitHub(), ssh: FakeSSH())
        let pauseResponse = await Daemon.handle(RPCRequest(id: 5, method: .pause), engine: engine)
        XCTAssertTrue(pauseResponse.ok)
        var status = await engine.status()
        XCTAssertTrue(status.paused)
        let resumeResponse = await Daemon.handle(RPCRequest(id: 6, method: .resume), engine: engine)
        XCTAssertTrue(resumeResponse.ok)
        status = await engine.status()
        XCTAssertFalse(status.paused)
    }
}
