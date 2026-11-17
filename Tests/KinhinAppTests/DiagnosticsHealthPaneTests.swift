import AppKit
import SwiftUI
import XCTest

@testable import KinhinKit
@testable import kinhin_app

/// The Health pane of the Diagnostics section.
@MainActor
final class DiagnosticsHealthPaneTests: MainWindowTestCase {
    // MARK: - Health pane

    /// Opens Diagnostics the way the Fleet screen's button does,
    /// but with a fixture report — never the live doctor probe, which would
    /// subprocess-spam the host. Returns once the load has rendered.
    @discardableResult
    private func openDiagnostics(withFixture fixture: Data) async throws -> (DiagnosticsModel, probes: Int) {
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

    func testDiagnosticsButtonOpensTheHealthPaneAndRendersTheReport() async throws {
        let (model, probes) = try await openDiagnostics(withFixture: doctorFixture())
        XCTAssertEqual(
            tabs.selectedSection, .diagnostics, "opens the Diagnostics section, inline rather than as a sheet")
        XCTAssertEqual(tabs.diagnosticsPane, .health)
        XCTAssertNil(tabs.sheet)
        XCTAssertEqual(probes, 1, "opening probes once")

        let titles = model.rows.map(\.title)
        XCTAssertEqual(
            titles,
            [
                "Host", "Command Line Tools", "Tart (macOS VMs)", "Apple container (Linux)", "Capacity",
                "Toolchain cache",
            ])
        XCTAssertTrue(model.rows.allSatisfy(\.ok), "the fixture report is all green")
    }

    func testDiagnosticsModelIsReusedAcrossPresentations() async throws {
        let (first, _) = try await openDiagnostics(withFixture: doctorFixture())
        tabs.select(.fleet)
        tabs.select(.diagnostics)
        XCTAssertTrue(models.ensureDiagnosticsModel() === first, "re-opening keeps the same model")
    }

    /// Re-check probes again, and a second request while one is running does nothing.
    func testRecheckProbesAgainAndIgnoresAClickWhileChecking() async throws {
        let model = DiagnosticsModel()
        let report = try JSONDecoder().decode(DoctorReport.self, from: doctorFixture())
        var probes = 0
        model.loadReport = {
            probes += 1
            try? await Task.sleep(for: .milliseconds(50))  // keep the probe open so the second call overlaps it
            return report
        }
        async let first: Void = model.load()
        try await Task.sleep(for: .milliseconds(10))
        XCTAssertTrue(model.isChecking, "the Re-check button disables while probing")
        await model.load()
        await first
        XCTAssertEqual(probes, 1, "an overlapping re-check is ignored")
        XCTAssertFalse(model.isChecking)
        await model.load()
        XCTAssertEqual(probes, 2, "a later re-check probes again")
        XCTAssertTrue(model.status.hasPrefix("Checked"), "the header shows when it was checked")
    }
}
