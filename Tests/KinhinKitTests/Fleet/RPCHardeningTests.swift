import XCTest

@testable import KinhinKit

/// Small RPC and attribution details: the ping reply's compatibility, the
/// accept loop's back-off, and the runner-name lookup.
final class RPCHardeningTests: XCTestCase {
    // MARK: - Ping

    func testPingReplyCarriesProtocolAndVersion() throws {
        let data = try JSONEncoder().encode(PingReply())
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(object["pong"] as? Bool, true)
        XCTAssertEqual(object["protocol"] as? Int, PingReply.currentProtocol)
        XCTAssertEqual(object["version"] as? String, kinhinVersion.current)
    }

    func testAPreFieldDaemonsPongDecodesWithNilVersions() throws {
        let old = Data(#"{"pong":true}"#.utf8)
        let reply = try JSONDecoder().decode(PingReply.self, from: old)
        XCTAssertTrue(reply.pong)
        XCTAssertNil(reply.protocolVersion)
        XCTAssertNil(reply.version)
    }

    func testAnOldClientsBooleanDictionaryDecodeStillSeesPong() throws {
        // Old clients only check `ok`; one that decoded `[String: Any]` keeps working too.
        let data = try JSONEncoder().encode(PingReply())
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(object["pong"] as? Bool, true)
    }

    // MARK: - Accept loop

    func testAcceptRetriesAtOnceOnlyForSignalsAndAbortedClients() {
        XCTAssertEqual(RPCServer.acceptRetryDelay(errno: EINTR, consecutiveFailures: 5), 0)
        XCTAssertEqual(RPCServer.acceptRetryDelay(errno: ECONNABORTED, consecutiveFailures: 5), 0)
    }

    func testAcceptBacksOffExponentiallyUpToASecondOnDescriptorExhaustion() {
        let delays = (1...10).map { RPCServer.acceptRetryDelay(errno: EMFILE, consecutiveFailures: $0) }
        XCTAssertEqual(delays.first, 0.05)
        XCTAssertEqual(delays[1], 0.1)
        XCTAssertEqual(delays.last, 1.0)
        XCTAssertEqual(delays, delays.sorted(), "the delay never shrinks within a streak")
    }

    // MARK: - Runner names

    func testRunnerNamesMapToTheirVM() {
        let ids: Set<String> = ["kinhin-1-aaaa", "kinhin-2-bbbb"]
        func vm(_ name: String, rpv: Int = 2) -> String? {
            FleetEngine.vmID(forRunnerName: name, among: ids, runnersPerVM: rpv)
        }
        XCTAssertEqual(vm("kinhin-1-aaaa"), "kinhin-1-aaaa")
        XCTAssertEqual(vm("kinhin-2-bbbb-r2"), "kinhin-2-bbbb")
        XCTAssertNil(vm("kinhin-2-bbbb-r3"), "index beyond runners_per_vm")
        XCTAssertNil(vm("kinhin-2-bbbb-r0"))
        XCTAssertNil(vm("kinhin-9-zzzz-r1"), "unknown VM")
        XCTAssertNil(vm("someone-elses-runner"))
        XCTAssertEqual(vm("kinhin-1-aaaa-r1", rpv: 1), "kinhin-1-aaaa", "at least one runner index is always valid")
    }
}
