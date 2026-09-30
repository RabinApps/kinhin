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
        window.render(status: nil)
        XCTAssertEqual(window.fleetModel.statusLine, "Needs setup — open the Setup tab")
        XCTAssertTrue(window.tabViews[.fleet] is NSHostingView<FleetView>)
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

        window.render(status: status)

        // The exact same line the menu renders — one renderer, two surfaces.
        let model = window.fleetModel
        XCTAssertEqual(model.statusLine, FleetStatusFormatter.summary(status))
        XCTAssertEqual(model.records.map(\.id), ["kinhin-vm-test", "kinhin-vm-idle"], "one row per VM")
        XCTAssertTrue(model.title(for: busy).contains("kinhin-vm-test — busy"))
        XCTAssertTrue(model.detail(for: busy).contains("2 repos"))
        // Current-jobs section: only the record carrying a job, with repo.
        XCTAssertEqual(model.working.map(\.id), ["kinhin-vm-test"])
        XCTAssertTrue(model.jobLine(for: busy).contains("build — alpha/one, beta/two"))
    }

    func testRenderIdleFleetShowsNoVMsAndNoJobs() {
        window.render(status: FleetStatus())
        XCTAssertTrue(window.fleetModel.records.isEmpty)
        XCTAssertTrue(window.fleetModel.working.isEmpty)
    }

    func testRenderTogglesPauseButtonTitle() {
        window.render(status: FleetStatus())
        XCTAssertEqual(window.fleetModel.pauseTitle, "Pause")

        var status = FleetStatus()
        status.running = true
        status.paused = true
        window.render(status: status)
        XCTAssertEqual(window.fleetModel.pauseTitle, "Resume")
    }

    func testPausedAutoResumeNoteShowsOnlyWhenThePolicyIsOn() {
        var status = FleetStatus()
        status.running = true
        status.paused = true
        window.render(status: status)
        XCTAssertNil(window.fleetModel.pausedAutoResumeNote, "policy off: no note")

        status.autoResume = true
        window.render(status: status)
        XCTAssertEqual(
            window.fleetModel.pausedAutoResumeNote,
            "Auto-resume is on — the fleet releases itself when the queue is empty.")
    }

    func testPausedAutoResumeNoteCountsDownToTheNextQueueCheck() {
        var status = FleetStatus()
        status.running = true
        status.paused = true
        status.autoResume = true
        status.pollInterval = 15
        window.render(status: status)
        XCTAssertEqual(
            window.fleetModel.pausedAutoResumeNote,
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
        window.render(status: status)
        let line = window.fleetModel.statusLine
        XCTAssertTrue(line.contains("\n  ⏱ queue age: "), "the tab carries the same freshness line: \(line)")
        XCTAssertFalse(line.contains("stale"), "fresh within the cadence: \(line)")

        status.queuePolledAt = Date().addingTimeInterval(-9_999)
        window.render(status: status)
        XCTAssertTrue(
            window.fleetModel.statusLine.contains("s old (stale — a forge poll failed or the engine is stopped)"),
            "an outage must not read as fresh: \(window.fleetModel.statusLine)")
    }

    func testRenderMarksErrorRows() {
        var failed = VMRecord(id: "kinhin-vm-err", phase: .failed)
        failed.createdAt = Date()
        failed.error = "boot timed out"
        window.render(status: FleetStatus(records: [failed]))
        XCTAssertTrue(window.fleetModel.detail(for: failed).contains("⚠︎ boot timed out"))
    }

    // MARK: - Delegate plumbing

    func testFleetControlButtonsReachTheDelegate() {
        window.fleetModel.onStart()
        window.fleetModel.onStop()
        XCTAssertEqual(delegate.startCalls, 1)
        XCTAssertEqual(delegate.stopCalls, 1)
    }

    // MARK: - In-flight start/stop (progress + disabled controls)

    func testStartClickMarksPendingUntilTheActionEnds() {
        window.fleetModel.startClicked()
        XCTAssertEqual(window.fleetModel.pendingAction, .start)
        XCTAssertTrue(window.fleetModel.isBusy)
        XCTAssertEqual(delegate.startCalls, 1, "the click still dispatches")

        // The action owner clears it when the command and refresh are done.
        window.fleetModel.endPendingAction()
        XCTAssertNil(window.fleetModel.pendingAction)
        XCTAssertFalse(window.fleetModel.isBusy)
    }

    func testStopClickMarksPendingAndIgnoresDoubleClicks() {
        window.render(
            status: {
                var s = FleetStatus(); s.running = true; return s
            }())
        window.fleetModel.stopClicked()
        XCTAssertEqual(window.fleetModel.pendingAction, .stop)
        XCTAssertEqual(delegate.stopCalls, 1)

        // A second click while busy must not dispatch again (state backstop
        // behind the disabled buttons).
        window.fleetModel.stopClicked()
        window.fleetModel.startClicked()
        XCTAssertEqual(delegate.stopCalls, 1)
        XCTAssertEqual(delegate.startCalls, 0)

        window.fleetModel.endPendingAction()
        XCTAssertNil(window.fleetModel.pendingAction)
    }

    func testPauseToggleIsIgnoredWhileBusy() {
        window.render(status: FleetStatus())  // not paused, not busy
        window.fleetModel.startClicked()
        window.fleetModel.togglePause()
        XCTAssertEqual(delegate.pauseCalls, 0, "no pause/resume during a start/stop")
        XCTAssertEqual(delegate.resumeCalls, 0)
        window.fleetModel.endPendingAction()
        window.fleetModel.togglePause()
        XCTAssertEqual(delegate.pauseCalls, 1)
    }

    func testPauseButtonDispatchesBasedOnRenderedState() {
        window.render(status: FleetStatus())  // not paused
        window.fleetModel.togglePause()
        XCTAssertEqual(delegate.pauseCalls, 1)
        XCTAssertEqual(delegate.resumeCalls, 0)

        var status = FleetStatus()
        status.paused = true
        window.render(status: status)
        window.fleetModel.togglePause()
        XCTAssertEqual(delegate.pauseCalls, 1)
        XCTAssertEqual(delegate.resumeCalls, 1)
    }

    func testUpdateCheckLivesInSettingsNotTheFleetTab() {
        window.showAdvanced(.app)
        window.appModel.onCheckForUpdates()
        XCTAssertEqual(delegate.updateCalls, 1)
    }

    func testUpdateCardRendersEachState() {
        window.showAdvanced(.app)
        let model = window.appModel
        window.renderUpdate(state: .checking)
        XCTAssertFalse(model.updateButtonEnabled)
        XCTAssertTrue(model.updateText.contains("checking…"))

        window.renderUpdate(state: .available(version: "9.9.9"))
        XCTAssertEqual(model.updateButtonTitle, "Download…")
        XCTAssertTrue(model.updateText.contains("Update available — kinhin 9.9.9"))

        window.renderUpdate(state: .upToDate(lastChecked: nil))
        XCTAssertTrue(model.updateText.contains("is up to date"))
        XCTAssertTrue(model.updateButtonEnabled)

        window.renderUpdate(state: .failed("offline"))
        XCTAssertTrue(model.updateText.contains("Update check failed: offline"))
    }

    func testFleetButtonsShowOnlyApplicableActions() {
        window.render(status: FleetStatus())  // stopped
        XCTAssertFalse(window.fleetModel.running, "stopped shows Start only")

        var status = FleetStatus()
        status.running = true
        window.render(status: status)
        XCTAssertTrue(window.fleetModel.running, "running shows Stop and Pause")
    }

    func testLogsSheetRendersSearchableViewer() throws {
        window.fleetModel.onShowLogs()
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        let model = try XCTUnwrap(window.logsModel, "the Logs… button creates the viewer")
        defer { if let sheet = window.window?.attachedSheet { window.window?.endSheet(sheet) } }
        // The viewer is SwiftUI-hosted; its state lives in the model.
        XCTAssertEqual(model.query, "", "the search starts empty")
        XCTAssertEqual(model.minLevel, .debug, "level filter present, defaulting to All")
        XCTAssertEqual(LogsModel.levels.first?.title, "All")
        // "1 line" or "N lines", depending on what earlier tests logged.
        let status = model.statusText
        XCTAssertTrue(status.hasSuffix(" line") || status.hasSuffix(" lines"), "a line count is shown")
        let sheet = try XCTUnwrap(window.logsSheet, "the logs sheet exists")
        XCTAssertGreaterThan(sheet.contentView?.frame.width ?? 0, 0, "the viewer is laid out inside the sheet")
    }

    func testDeleteButtonCarriesTheVMID() {
        var record = VMRecord(id: "kinhin-vm-del", phase: .ready)
        record.createdAt = Date()
        window.render(status: FleetStatus(records: [record]))
        window.fleetModel.onDeleteVM("kinhin-vm-del")
        XCTAssertEqual(delegate.deletedVMIDs, ["kinhin-vm-del"])
    }
}
