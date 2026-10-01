import XCTest

@testable import KinhinKit
@testable import kinhin_app

@MainActor
final class DiagnosticsSecurityRowTests: XCTestCase {
    private func report(security: String) throws -> DoctorReport {
        let json = """
            {
              "host": {"logicalCores": 10, "memoryGB": 32, "freeDiskGB": 200, "arm64": true},
              "clt": {"state": "ok", "version": "26.0", "ok": true, "fixCommand": null, "fixHint": null},
              "tart": {"state": "healthy", "ok": true, "reason": null, "repairCommands": []},
              "container": null, "docker": null, "dockerAvailability": null,
              "toolchainCache": {"root": "/tmp/c", "usable": true, "sharedWithRunners": false, "warning": false, "totalBytes": 0, "ecosystems": []},
              "auth": {"forges": [], "allGood": true},
              "checks": [], "ready": true, "capacity": null\(security)
            }
            """
        return try JSONDecoder().decode(DoctorReport.self, from: Data(json.utf8))
    }

    private func row(_ security: String) throws -> DiagnosticsModel.Row? {
        let model = DiagnosticsModel()
        model.render(try report(security: security))
        return model.rows.first { $0.title == "Isolation & transport" }
    }

    func testNoRowForAReportWithoutTheSection() throws {
        XCTAssertNil(try row(""), "older documents decode without a security section")
    }

    func testSoftnetOffShowsTheAdvisory() throws {
        let row = try XCTUnwrap(
            try row(
                #", "security": {"softnetEnabled": false, "softnetInstalled": false, "ok": true, "fix": null, "insecureHTTPAccounts": [], "sharedCacheWritable": false, "warnings": ["VMs share one network"]}"#
            ))
        XCTAssertTrue(row.detail.contains("Softnet off"))
        XCTAssertTrue(row.ok)
        XCTAssertEqual(row.warning, "VMs share one network")
    }

    func testSoftnetEnabledButMissingIsAFailure() throws {
        let row = try XCTUnwrap(
            try row(
                #", "security": {"softnetEnabled": true, "softnetInstalled": false, "ok": false, "fix": "brew install cirruslabs/cli/softnet", "insecureHTTPAccounts": [], "sharedCacheWritable": false, "warnings": []}"#
            ))
        XCTAssertFalse(row.ok)
        XCTAssertTrue(row.detail.contains("brew install cirruslabs/cli/softnet"))
        XCTAssertNil(row.warning)
    }
}
