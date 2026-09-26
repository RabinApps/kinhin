import AppKit
import SwiftUI
import XCTest

@testable import KinhinKit
@testable import kinhin_app

/// The Diagnostics sheet hosted by the main window.
@MainActor
final class DiagnosticsSheetTests: MainWindowTestCase {
    // MARK: - Diagnostics sheet

    /// Presents the diagnostics sheet the same way the Fleet tab's button
    /// does (beginSheet on the main window) but with a fixture report —
    /// never the live doctor probe, which would subprocess-spam the host.
    @discardableResult
    private func presentDiagnosticsSheet(withFixture fixture: Data) throws -> DiagnosticsModel {
        window.makeDiagnosticsSheet()
        let model = try XCTUnwrap(window.diagnosticsModel, "the sheet builds its model")
        let sheet = try XCTUnwrap(window.diagnosticsWindow)
        window.window!.beginSheet(sheet) { _ in }
        // Attachment completes on the run loop — spin until sheetParent is
        // set so Close (endSheet) is driven the way a real click sees it.
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        model.render(try JSONDecoder().decode(DoctorReport.self, from: fixture))
        sheet.layoutIfNeeded()
        return model
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

    func testDiagnosticsSheetRendersTheReportAtNonZeroWidth() throws {
        let model = try presentDiagnosticsSheet(withFixture: doctorFixture())
        let sheet = try XCTUnwrap(window.diagnosticsWindow)
        defer { if let parent = sheet.sheetParent { parent.endSheet(sheet) } }
        XCTAssertNotNil(sheet.sheetParent, "presented as a sheet on the main window")

        // Regression: the report used to collapse to 0x0 and render nothing.
        // It must lay out at the sheet's size and carry every check row.
        let host = try XCTUnwrap(sheet.contentView as? NSHostingView<DiagnosticsView>, "the sheet hosts the report")
        XCTAssertGreaterThan(host.frame.width, 300, "report must span the sheet, got \(host.frame)")

        let titles = model.rows.map(\.title)
        XCTAssertEqual(
            titles,
            [
                "Host", "Command Line Tools", "Tart (macOS VMs)", "Apple container (Linux)", "Capacity",
                "Toolchain cache",
            ])
        XCTAssertTrue(model.rows.allSatisfy(\.ok), "the fixture report is all green")
    }

    func testDiagnosticsCloseEndsTheSheet() throws {
        let model = try presentDiagnosticsSheet(withFixture: doctorFixture())
        let sheet = try XCTUnwrap(window.diagnosticsWindow)

        // Regression: dismiss(_:) is a no-op for beginSheet presentation —
        // only the parent's endSheet(_) ends a sheet, so Close did nothing.
        window.closeDiagnosticsSheet()
        // endSheet detaches after the sheet's exit animation completes on
        // the run loop — spin it so the detach is observed. Detachment is
        // measured on the sheet window itself: the content stays installed
        // inside the hidden sheet window (so the sheet can re-open),
        // meaning contentView is never nil.
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        XCTAssertNil(sheet.sheetParent, "Close must detach the sheet from its parent")
        XCTAssertFalse(sheet.isVisible, "Close must hide the sheet")
        _ = model
    }

    func testDiagnosticsRefreshOnlyWhenTheSheetExists() async throws {
        // No sheet → the poll-loop refresh is a no-op (never probes).
        XCTAssertNil(window.diagnosticsWindow)
        window.makeDiagnosticsSheet()
        let model = try XCTUnwrap(window.diagnosticsModel)
        let report = try JSONDecoder().decode(DoctorReport.self, from: doctorFixture())
        var probes = 0
        model.loadReport = {
            probes += 1
            return report
        }
        await window.refreshDiagnosticsIfVisible()
        XCTAssertEqual(probes, 1, "the visible sheet's model is refreshed")
        XCTAssertEqual(model.rows.first?.title, "Host", "the probe result is rendered")
    }
}
