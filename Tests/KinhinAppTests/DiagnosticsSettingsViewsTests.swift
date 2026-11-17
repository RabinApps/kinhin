import AppKit
import SwiftUI
import XCTest

@testable import KinhinKit
@testable import kinhin_app

/// The redesigned Diagnostics panes, Settings page and their sheets: each state renders to a non-empty layout, and the
/// copy and tones the design fixes stay put.
@MainActor
final class DiagnosticsSettingsViewsTests: MainWindowTestCase {
    private func fittingSize<V: View>(_ view: V, width: CGFloat = 640) -> CGSize {
        let host = NSHostingView(rootView: view.frame(width: width))
        return host.fittingSize
    }

    private func event(_ id: String, _ outcome: HealingEvent.Outcome) -> HealingEvent {
        HealingEvent(
            id: id, signal: HealingSignal(kind: .diskPressure, detail: "disk full"),
            remediation: Remediation(.pruneImages), source: .advisor, outcome: outcome, detail: "detail of \(id)",
            explanation: "because")
    }

    // MARK: - Health and Healing

    func testHealthPaneRendersRowsAndTheReCheckButton() {
        let model = DiagnosticsModel.previewModel()
        XCTAssertFalse(model.isChecking)
        XCTAssertGreaterThan(fittingSize(DiagnosticsView(model: model)).height, 100)
    }

    func testEveryHealingOutcomeHasItsTone() {
        let tones: [HealingEvent.Outcome: Chip.Tone] = [
            .pending: .warn, .surfaced: .error, .running: .accent, .succeeded: .ok, .resolved: .ok, .failed: .error,
            .dismissed: .neutral, .expired: .neutral,
        ]
        for (outcome, tone) in tones {
            let item = HealingPresentation.Item(event("e", outcome))
            XCTAssertEqual(item.chipTone, tone, "\(outcome)")
        }
    }

    func testHealingCardRendersEveryGroupTheOffStateAndTheQuietState() {
        let busy = HealingPresentation(
            HealingSnapshot(
                enabled: true, automatic: true, advisor: "Claude Haiku",
                events: [event("a", .pending), event("b", .surfaced), event("c", .running), event("d", .succeeded)]))
        let off = HealingPresentation(HealingSnapshot(enabled: false, automatic: false, advisor: nil, events: []))
        let quiet = HealingPresentation(HealingSnapshot(enabled: true, automatic: true, advisor: nil, events: []))
        for healing in [busy, off, quiet] {
            let view = HealingSectionView(healing: healing, busyIDs: ["a"], approve: { _ in }, dismiss: { _ in })
            XCTAssertGreaterThan(fittingSize(view).height, 40)
        }
        XCTAssertTrue(quiet.isQuiet)
        XCTAssertGreaterThan(
            fittingSize(HealingSectionView(healing: busy, busyIDs: [], approve: { _ in }, dismiss: { _ in })).height,
            fittingSize(HealingSectionView(healing: quiet, busyIDs: [], approve: { _ in }, dismiss: { _ in })).height,
            "the groups add rows")
    }

    // MARK: - Panes and sheets

    func testLogsToolsContainersAndBenchmarksPanesRender() {
        let logs = models.ensureLogsModel()
        XCTAssertGreaterThan(fittingSize(LogsPane(model: logs, openFolder: {})).height, 50)
        XCTAssertGreaterThan(fittingSize(ToolsPane(testWorkflow: {}, makeVideo: {})).height, 100)
        if let containers = models.containersModel {
            XCTAssertGreaterThan(fittingSize(ContainersView(model: containers)).height, 50)
        }
        if let benchmarks = models.benchmarksModel {
            XCTAssertGreaterThan(fittingSize(BenchmarksView(model: benchmarks)).height, 50)
        }
    }

    func testSheetsRender() {
        XCTAssertGreaterThan(fittingSize(SponsorSheet(close: {}), width: 380).height, 100)
        XCTAssertGreaterThan(
            fittingSize(WorkflowTestView(model: WorkflowTestModel(), onClose: {}), width: 620).height, 100)
        XCTAssertGreaterThan(fittingSize(VideosView(model: VideosModel(), onClose: {}), width: 640).height, 100)
    }

    // MARK: - Settings

    func testLaunchModesReadAsTheDesignNamesThem() {
        XCTAssertEqual(LaunchMode.mainWindowAndMenuBar.label, "Window + menu bar")
        XCTAssertEqual(LaunchMode.mainWindowOnly.label, "Window only")
        XCTAssertEqual(LaunchMode.menuBarOnly.label, "Menu bar only")
    }

    func testSettingsPageRendersWithTheDaemonAndResetStates() {
        let view = AppSectionView(
            model: models.appModel, telemetry: models.telemetryModel, alerts: models.alertsModel, openSupport: {})
        XCTAssertGreaterThan(fittingSize(view, width: 720).height, 200)
    }

    func testAlertWebhookSheetRendersAddAndEdit() {
        models.alertsModel.beginAdd()
        XCTAssertNotNil(models.alertsModel.draft)
        XCTAssertGreaterThan(fittingSize(AlertWebhookSheet(model: models.alertsModel), width: 480).height, 100)
        models.alertsModel.cancelDraft()
    }
}
