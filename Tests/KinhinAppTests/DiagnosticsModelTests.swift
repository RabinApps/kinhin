import XCTest

@testable import KinhinKit
@testable import kinhin_app

@MainActor
final class DiagnosticsModelTests: XCTestCase {
    /// A minimal report with no `docker:` config, only the availability half.
    private func report(dockerAvailability: String) throws -> DoctorReport {
        let json = """
            {
              "host": {"logicalCores": 10, "memoryGB": 32, "freeDiskGB": 200, "arm64": true},
              "clt": {"state": "ok", "version": "26.0", "ok": true, "fixCommand": null, "fixHint": null},
              "tart": {"state": "healthy", "ok": true, "reason": null, "repairCommands": []},
              "container": null,
              "docker": null,
              "dockerAvailability": \(dockerAvailability),
              "toolchainCache": {"root": "/tmp/c", "usable": true, "sharedWithRunners": false, "warning": false, "totalBytes": 0, "ecosystems": []},
              "auth": {"forges": [], "allGood": true},
              "checks": [],
              "ready": true,
              "capacity": null
            }
            """
        return try JSONDecoder().decode(DoctorReport.self, from: Data(json.utf8))
    }

    private func dockerRow(_ availability: String) throws -> DiagnosticsModel.Row? {
        let model = DiagnosticsModel()
        model.render(try report(dockerAvailability: availability))
        return model.rows.first { $0.title == "Docker (Linux)" }
    }

    func testDockerRowAppearsWhenNotConfiguredButMissing() throws {
        let row = try XCTUnwrap(try dockerRow(#"{"installed": false, "supported": true, "reason": null}"#))
        XCTAssertTrue(row.detail.contains("not installed"))
        XCTAssertTrue(row.ok, "Docker is optional, so missing isn't a failure")
    }

    func testDockerRowSaysInstalledButNotEnabled() throws {
        let row = try XCTUnwrap(try dockerRow(#"{"installed": true, "supported": true, "reason": null}"#))
        XCTAssertTrue(row.detail.contains("installed — not enabled"))
    }

    func testDockerRowExplainsAnUnsupportedMac() throws {
        let row = try XCTUnwrap(try dockerRow(#"{"installed": false, "supported": false, "reason": "needs more RAM"}"#))
        XCTAssertTrue(row.detail.contains("needs more RAM"))
        XCTAssertFalse(row.ok)
    }

    func testOlderReportsWithoutAvailabilityRenderNoDockerRow() throws {
        XCTAssertNil(try dockerRow("null"))
    }
}
