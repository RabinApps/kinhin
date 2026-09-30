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

    // MARK: - Base image drift warning

    /// A healthy report plus an optional `tartBaseImage` section (nil
    /// reference = the key isn't set, so the builder omits the section).
    /// The section is encoded through JSONEncoder so the warning text needs
    /// no hand-escaping, and this doubles as a check that the report's JSON
    /// contract decodes the section.
    private func render(reference: String?, warning: String?) throws -> DiagnosticsModel.Row? {
        var json =
            """
            {
              "host": {"logicalCores": 10, "memoryGB": 32, "freeDiskGB": 200, "arm64": true},
              "clt": {"state": "ok", "version": "26.0", "ok": true, "fixCommand": null, "fixHint": null},
              "tart": {"state": "healthy", "ok": true, "reason": null, "repairCommands": []},
              "container": null,
              "docker": null,
              "toolchainCache": {"root": "/tmp/c", "usable": true, "sharedWithRunners": false, "warning": false, "totalBytes": 0, "ecosystems": []},
              "auth": {"forges": [], "allGood": true},
              "checks": [],
              "ready": true,
              "capacity": null
            }
            """
        if let reference {
            struct Section: Encodable {
                var reference: String
                var state: String
                var ok: Bool
                var fix: String?
                var pinned: Bool
                var warning: String?
            }
            let section = Section(
                reference: reference, state: "known", ok: true, fix: nil, pinned: false, warning: warning)
            let encoded = try JSONEncoder().encode(section)
            json = json.dropLast() + ",\n  \"tartBaseImage\": \(String(data: encoded, encoding: .utf8)!)\n}"
        }
        let model = DiagnosticsModel()
        model.render(try JSONDecoder().decode(DoctorReport.self, from: Data(json.utf8)))
        return model.rows.first { $0.title == "Base image (macOS VMs)" }
    }

    func testMutableBaseImageRowCarriesTheSharedDriftWarning() throws {
        // The builder computes `warning` from the same
        // `TartBaseImage.mutableTagWarning` line the fleet-start log prints.
        let reference = "ghcr.io/cirruslabs/macos-sequoia-base:latest"
        let warning = try XCTUnwrap(TartBaseImage.mutableTagWarning(for: reference))
        let row = try XCTUnwrap(try render(reference: reference, warning: warning))
        XCTAssertEqual(row.warning, warning)
        XCTAssertTrue(row.ok, "a usable base image stays green — the caveat is advisory")
        XCTAssertTrue(row.detail.contains(reference))
        XCTAssertTrue(warning.contains("pin a digest"), "the shared wording survived")
    }

    func testPinnedBaseImageRendersNoRow() throws {
        let reference = "ghcr.io/cirruslabs/macos-sequoia-base@sha256:\(String(repeating: "a", count: 64))"
        XCTAssertNil(
            try render(reference: reference, warning: nil),
            "pinned = reproducible = nothing to warn about")
    }

    func testAbsentBaseImageRendersNoRow() throws {
        XCTAssertNil(try render(reference: nil, warning: nil), "no base_image: key → no row")
    }
}
