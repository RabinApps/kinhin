import AppKit
import SwiftUI
import XCTest

@testable import KinhinKit
@testable import kinhin_app

/// The Fleet tab: status rendering and the controls that reach the delegate.
@MainActor
final class FleetTabTests: MainWindowTestCase {
    // MARK: - Fleet tab rendering

    func testRenderShowsNeedsSetupBeforeFirstStatus() {
        fleet.status = nil
        XCTAssertEqual(models.fleetModel.statusLine, "Needs setup — open the Setup tab")
    }

    func testRenderShowsSharedStatusLineVMRowsAndCurrentJobs() {
        var status = FleetStatus()
        status.running = true
        status.queueDepth = 2
        status.desired = 1
        status.capacityCap = 3
        status.jobCapacity = 4
        var busy = VMRecord(id: "kinhin-vm-test", phase: .busy)
        busy.createdAt = Date()
        busy.repos = ["alpha/one", "beta/two"]
        busy.job = "build"
        status.records = [
            busy,
            {
                var ready = VMRecord(id: "kinhin-vm-idle", phase: .ready)
                ready.createdAt = Date()
                return ready
            }(),
        ]

        fleet.status = status

        // The exact same line the menu renders — one renderer, two surfaces.
        let model = models.fleetModel
        XCTAssertEqual(model.statusLine, FleetStatusFormatter.summary(status))
        XCTAssertEqual(model.records.map(\.id), ["kinhin-vm-test", "kinhin-vm-idle"], "one row per VM")
        XCTAssertTrue(model.title(for: busy).contains("kinhin-vm-test — busy"))
        XCTAssertTrue(model.detail(for: busy).contains("2 repos"))
        // Current-jobs section: only the record carrying a job, with repo.
        XCTAssertEqual(model.working.map(\.id), ["kinhin-vm-test"])
        XCTAssertTrue(model.jobLine(for: busy).contains("build — alpha/one, beta/two"))
    }

    func testRenderIdleFleetShowsNoVMsAndNoJobs() {
        fleet.status = FleetStatus()
        XCTAssertTrue(models.fleetModel.records.isEmpty)
        XCTAssertTrue(models.fleetModel.working.isEmpty)
    }

    func testRenderTogglesPauseButtonTitle() {
        fleet.status = FleetStatus()
        XCTAssertEqual(models.fleetModel.pauseTitle, "Pause")

        var status = FleetStatus()
        status.running = true
        status.paused = true
        fleet.status = status
        XCTAssertEqual(models.fleetModel.pauseTitle, "Resume")
    }

    func testPausedAutoResumeNoteShowsOnlyWhenThePolicyIsOn() {
        var status = FleetStatus()
        status.running = true
        status.paused = true
        fleet.status = status
        XCTAssertNil(models.fleetModel.pausedAutoResumeNote, "policy off: no note")

        status.autoResume = true
        fleet.status = status
        XCTAssertEqual(
            models.fleetModel.pausedAutoResumeNote,
            "Auto-resume is on — the fleet releases itself when the queue is empty.")
    }

    func testPausedAutoResumeNoteCountsDownToTheNextQueueCheck() {
        var status = FleetStatus()
        status.running = true
        status.paused = true
        status.autoResume = true
        status.pollInterval = 15
        fleet.status = status
        XCTAssertEqual(
            models.fleetModel.pausedAutoResumeNote,
            "Auto-resume is on — the engine re-checks the queue every 15s and resumes once it's empty.")
    }

    func testPausedSnapshotShowsQueueAgeOnTheTab() {
        var status = FleetStatus()
        status.running = true
        status.paused = true
        status.autoResume = true
        status.pollInterval = 20
        status.queueDepth = 3
        status.queuePolledAt = Date().addingTimeInterval(-2)
        fleet.status = status
        let line = models.fleetModel.statusLine
        XCTAssertTrue(line.contains("\n  ⏱ queue age: "), "the tab carries the same freshness line: \(line)")
        XCTAssertFalse(line.contains("stale"), "fresh within the cadence: \(line)")

        status.queuePolledAt = Date().addingTimeInterval(-9_999)
        fleet.status = status
        XCTAssertTrue(
            models.fleetModel.statusLine.contains("s old (stale — a forge poll failed or the engine is stopped)"),
            "an outage must not read as fresh: \(models.fleetModel.statusLine)")
    }

    func testRenderMarksErrorRows() {
        var failed = VMRecord(id: "kinhin-vm-err", phase: .failed)
        failed.createdAt = Date()
        failed.error = "boot timed out"
        fleet.status = FleetStatus(records: [failed])
        XCTAssertTrue(models.fleetModel.detail(for: failed).contains("⚠︎ boot timed out"))
    }

    // MARK: - Delegate plumbing

    func testFleetControlButtonsReachTheDelegate() {
        models.fleetModel.onStart()
        models.fleetModel.onStop()
        XCTAssertEqual(delegate.startCalls, 1)
        XCTAssertEqual(delegate.stopCalls, 1)
    }

    // MARK: - In-flight start/stop (progress + disabled controls)

    func testStartClickMarksPendingUntilTheActionEnds() {
        models.fleetModel.startClicked()
        XCTAssertEqual(models.fleetModel.pendingAction, .start)
        XCTAssertTrue(models.fleetModel.isBusy)
        XCTAssertEqual(delegate.startCalls, 1, "the click still dispatches")

        // The action owner clears it when the command and refresh are done.
        fleet.pendingFleetAction = nil
        XCTAssertNil(models.fleetModel.pendingAction)
        XCTAssertFalse(models.fleetModel.isBusy)
    }

    func testStopClickMarksPendingAndIgnoresDoubleClicks() {
        fleet.status = {
            var s = FleetStatus(); s.running = true; return s
        }()
        models.fleetModel.stopClicked()
        XCTAssertEqual(models.fleetModel.pendingAction, .stop)
        XCTAssertEqual(delegate.stopCalls, 1)

        // A second click while busy must not dispatch again (state backstop
        // behind the disabled buttons).
        models.fleetModel.stopClicked()
        models.fleetModel.startClicked()
        XCTAssertEqual(delegate.stopCalls, 1)
        XCTAssertEqual(delegate.startCalls, 0)

        fleet.pendingFleetAction = nil
        XCTAssertNil(models.fleetModel.pendingAction)
    }

    func testPauseToggleIsIgnoredWhileBusy() {
        fleet.status = FleetStatus()  // not paused, not busy
        models.fleetModel.startClicked()
        models.fleetModel.togglePause()
        XCTAssertEqual(delegate.pauseCalls, 0, "no pause/resume during a start/stop")
        XCTAssertEqual(delegate.resumeCalls, 0)
        fleet.pendingFleetAction = nil
        models.fleetModel.togglePause()
        XCTAssertEqual(delegate.pauseCalls, 1)
    }

    func testPauseButtonDispatchesBasedOnRenderedState() {
        fleet.status = FleetStatus()  // not paused
        models.fleetModel.togglePause()
        XCTAssertEqual(delegate.pauseCalls, 1)
        XCTAssertEqual(delegate.resumeCalls, 0)

        var status = FleetStatus()
        status.paused = true
        fleet.status = status
        models.fleetModel.togglePause()
        XCTAssertEqual(delegate.pauseCalls, 1)
        XCTAssertEqual(delegate.resumeCalls, 1)
    }

    func testUpdateCheckLivesInSettingsNotTheFleetTab() {
        tabs.showAdvanced(.app)
        models.appModel.onCheckForUpdates()
        XCTAssertEqual(delegate.updateCalls, 1)
    }

    func testUpdateCardRendersEachState() {
        tabs.showAdvanced(.app)
        let model = models.appModel
        updates.updateCardState = .checking
        XCTAssertFalse(model.updateButtonEnabled)
        XCTAssertTrue(model.updateText.contains("checking…"))

        updates.updateCardState = .available(version: "9.9.9")
        XCTAssertEqual(model.updateButtonTitle, "Download…")
        XCTAssertTrue(model.updateText.contains("Update available — kinhin 9.9.9"))

        updates.updateCardState = .upToDate(lastChecked: nil)
        XCTAssertTrue(model.updateText.contains("is up to date"))
        XCTAssertTrue(model.updateButtonEnabled)

        updates.updateCardState = .failed("offline")
        XCTAssertTrue(model.updateText.contains("Update check failed: offline"))
    }

    func testFleetButtonsShowOnlyApplicableActions() {
        fleet.status = FleetStatus()  // stopped
        XCTAssertFalse(models.fleetModel.running, "stopped shows Start only")

        var status = FleetStatus()
        status.running = true
        fleet.status = status
        XCTAssertTrue(models.fleetModel.running, "running shows Stop and Pause")
    }

    func testLogsButtonPresentsTheSearchableViewer() throws {
        models.fleetModel.onShowLogs()
        XCTAssertEqual(tabs.sheet, .logs, "the Logs… button presents the sheet")
        let model = try XCTUnwrap(models.logsModel, "the Logs… button creates the viewer")
        // The viewer is SwiftUI-hosted; its state lives in the model.
        XCTAssertEqual(model.query, "", "the search starts empty")
        XCTAssertEqual(model.minLevel, .debug, "level filter present, defaulting to All")
        XCTAssertEqual(LogsModel.levels.first?.title, "All")
        // "1 line" or "N lines", depending on what earlier tests logged.
        let status = model.statusText
        XCTAssertTrue(status.hasSuffix(" line") || status.hasSuffix(" lines"), "a line count is shown")

        tabs.dismissSheet()
        XCTAssertNil(tabs.sheet)
    }

    func testDeleteButtonCarriesTheVMID() {
        var record = VMRecord(id: "kinhin-vm-del", phase: .ready)
        record.createdAt = Date()
        fleet.status = FleetStatus(records: [record])
        models.fleetModel.onDeleteVM("kinhin-vm-del")
        XCTAssertEqual(delegate.deletedVMIDs, ["kinhin-vm-del"])
    }
}
