import XCTest

@testable import KinhinKit
@testable import kinhin

/// The `kinhin status --json` contract: scripts read daemon/paused/autoResume
/// at the top level without descending into `fleet` or parsing prose.
final class StatusDocumentTests: XCTestCase {
    private func fleet(autoResume: Bool?, pollInterval: Int? = 20) -> FleetStatus {
        var status = FleetStatus()
        status.running = true
        status.paused = true
        status.autoResume = autoResume
        status.pollInterval = pollInterval
        return status
    }

    func testFlattensTheFieldsScriptsGateOn() throws {
        let document = StatusDocument(daemonRunning: true, fleet: fleet(autoResume: true))
        XCTAssertEqual(document.paused, true)
        XCTAssertEqual(document.autoResume, true)
        XCTAssertEqual(document.pollInterval, 20)
        XCTAssertEqual(document.running, true)
    }

    func testLegacyDaemonOmitsUnknownAutoResume() throws {
        // A daemon predating the field reports nil autoResume — omitted, so
        // "unknown" (absent) stays distinct from "off" (false).
        let data = try JSONEncoder().encode(StatusDocument(daemonRunning: true, fleet: fleet(autoResume: nil)))
        let json = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        XCTAssertNil(json["autoResume"], "unknown policy must be absent, got: \(json["autoResume"] ?? "nil")")
        XCTAssertEqual(json["paused"] as? Bool, true)
        XCTAssertTrue((json["fleet"] as! [String: Any])["paused"] as? Bool == true)

        let off = try JSONEncoder().encode(StatusDocument(daemonRunning: true, fleet: fleet(autoResume: false)))
        let offJSON = try JSONSerialization.jsonObject(with: off) as! [String: Any]
        XCTAssertEqual(offJSON["autoResume"] as? Bool, false, "off is explicit false, not absent")
    }

    func testNotRunningDocumentOmitsFleetFields() throws {
        let data = try JSONEncoder().encode(StatusDocument(daemonRunning: false, fleet: nil))
        let json = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        XCTAssertEqual(json["daemonRunning"] as? Bool, false)
        XCTAssertNil(json["fleet"])
        XCTAssertNil(json["paused"], "no daemon: no paused state to gate on")
        XCTAssertNil(json["autoResume"])
    }

    func testDocumentDecodesRoundTrip() throws {
        let document = StatusDocument(daemonRunning: true, fleet: fleet(autoResume: false))
        let decoded = try JSONDecoder().decode(StatusDocument.self, from: try JSONEncoder().encode(document))
        XCTAssertEqual(decoded, document)
    }
}
