import AppKit
import SwiftUI
import XCTest

@testable import KinhinKit
@testable import kinhin_app

/// The Diagnostics sheet hosted by the main window.
@MainActor
final class DiagnosticsSheetTests: MainWindowTestCase {
    // MARK: - Diagnostics sheet

    /// Presents the diagnostics sheet the way the Fleet tab's button does,
    /// but with a fixture report — never the live doctor probe, which would
    /// subprocess-spam the host. Returns once the load has rendered.
    @discardableResult
    private func presentDiagnosticsSheet(withFixture fixture: Data) async throws -> (DiagnosticsModel, probes: Int) {
        let model = models.ensureDiagnosticsModel()
        let report = try JSONDecoder().decode(DoctorReport.self, from: fixture)
        var probes = 0
        model.loadReport = {
            probes += 1
            return report
        }
        models.fleetModel.onShowDiagnostics()
        // The load runs in a Task started by the button; wait for the render.
        let deadline = Date().addingTimeInterval(5)
        while model.rows.isEmpty, Date() < deadline { try await Task.sleep(for: .milliseconds(10)) }
        return (model, probes)
    }

    /// DoctorReport's stable JSON contract doubles as the test fixture
    /// (the section structs' memberwise inits are internal to KinhinKit).
    private func doctorFixture() -> Data {
        """
        {
          "host": {"logicalCores": 10, "memoryGB": 32, "freeDiskGB": 200, "arm64": true},
          "clt": {"state": "ok", "version": "15.0", "ok": true, "fixCommand": null, "fixHint": null},
          "tart": {"state": "healthy", "ok": true, "reason": null, "repairCommands": []},
          "container": {"state": "ready", "ok": true, "fix": null, "image": "kinhin-runner:latest", "imageFound": true},
          "docker": null,
          "toolchainCache": {"root": "/tmp/kinhin-cache", "usable": true, "sharedWithRunners": true, "warning": false, "totalBytes": 1234, "ecosystems": []},
          "auth": {"forges": [{"id": "github", "stored": true, "prefix": "ghp_", "configured": true, "scope": "acme/repo", "instance": null, "detail": "ok"}], "allGood": true},
          "checks": [],
          "ready": true,
          "capacity": {"maxConcurrent": 4, "bindingConstraint": "cpu (need 4 cores per VM)", "fits": true, "jobSlots": 8}
        }
        """.data(using: .utf8)!
    }

    func testDiagnosticsButtonPresentsTheSheetAndRendersTheReport() async throws {
        let (model, probes) = try await presentDiagnosticsSheet(withFixture: doctorFixture())
        XCTAssertEqual(tabs.sheet, .diagnostics, "presented as a sheet on the main window")
        XCTAssertEqual(probes, 1, "presenting probes once")

        let titles = model.rows.map(\.title)
        XCTAssertEqual(
            titles,
            [
                "Host", "Command Line Tools", "Tart (macOS VMs)", "Apple container (Linux)", "Capacity",
                "Toolchain cache",
            ])
        XCTAssertTrue(model.rows.allSatisfy(\.ok), "the fixture report is all green")
    }

    func testDiagnosticsCloseDismissesTheSheet() async throws {
        _ = try await presentDiagnosticsSheet(withFixture: doctorFixture())
        XCTAssertEqual(tabs.sheet, .diagnostics)
        tabs.dismissSheet()
        XCTAssertNil(tabs.sheet, "Close must dismiss the sheet")
    }

    func testDiagnosticsModelIsReusedAcrossPresentations() async throws {
        let (first, _) = try await presentDiagnosticsSheet(withFixture: doctorFixture())
        tabs.dismissSheet()
        XCTAssertTrue(models.ensureDiagnosticsModel() === first, "re-opening keeps the same model")
    }
}
