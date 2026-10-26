import AppKit
import SwiftUI
import XCTest

@testable import KinhinKit
@testable import KinhinTestSupport
@testable import kinhin_app

/// The Fleet tab: status rendering and the controls that reach the delegate.
@MainActor
final class FleetTabTests: MainWindowTestCase {
    // MARK: - Fleet tab rendering

    func testRenderShowsNeedsSetupBeforeFirstStatus() {
        fleet.service = nil  // nothing configured yet
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
        // The VM list now lives inside the diagram's lanes.
        let instances = model.diagram.lanes.flatMap(\.instances)
        XCTAssertEqual(instances.map(\.id), ["kinhin-vm-test", "kinhin-vm-idle"], "one row per instance")
        XCTAssertTrue(instances[0].title.contains("kinhin-vm-test — busy"))
        XCTAssertTrue(instances[0].detail.contains("2 repos"))
        // Current-jobs section: only the record carrying a job, with repo.
        XCTAssertEqual(model.working.map(\.id), ["kinhin-vm-test#kinhin-vm-test"])
        XCTAssertTrue(model.jobLine(for: model.working[0]).contains("build — alpha/one, beta/two"))
    }

    func testCurrentJobsListsEveryRunnerOfAMultiRunnerVM() {
        var status = FleetStatus()
        var busy = VMRecord(id: "kinhin-vm-test", phase: .busy)
        busy.createdAt = Date()
        busy.job = "build"
        busy.repos = ["alpha/one"]
        busy.runningJobs = [
            RunningJobStamp(runner: "kinhin-vm-test-r1", job: "build", repo: "alpha/one"),
            RunningJobStamp(runner: "kinhin-vm-test-r2", job: "test", repo: "alpha/one"),
        ]
        status.records = [busy]
        fleet.status = status

        let rows = models.fleetModel.working
        XCTAssertEqual(rows.map(\.id), ["kinhin-vm-test#kinhin-vm-test-r1", "kinhin-vm-test#kinhin-vm-test-r2"])
        XCTAssertTrue(models.fleetModel.jobLine(for: rows[1]).contains("test — alpha/one  (kinhin-vm-test-r2, busy)"))
        let detail = models.fleetModel.diagram.lanes.flatMap(\.instances)[0].detail
        XCTAssertTrue(detail.contains("2 jobs: build, test"))
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
        XCTAssertTrue(
            models.fleetModel.diagram.lanes[0].instances[0].detail.contains("⚠︎ boot timed out"))
    }

    func testConfiguredFleetThatCannotBeReachedIsNotReportedAsNeedingSetup() async {
        fake.statusError = RPCError.timeout
        await fleet.refresh()
        XCTAssertTrue(models.fleetModel.statusLine.hasPrefix("Fleet not responding"), models.fleetModel.statusLine)
        XCTAssertFalse(models.fleetModel.statusLine.contains("Setup"))
    }

    func testConfiguredFleetBeforeTheFirstPollSaysItIsChecking() {
        XCTAssertEqual(models.fleetModel.statusLine, "Checking the fleet…")
    }

    // MARK: - Runtime diagram (top card)

    func testDiagramPlaceholderEchoesTheStatusHeadlineBeforeTheFirstPoll() {
        let model = models.fleetModel
        XCTAssertEqual(model.diagramPlaceholder, "Checking the fleet…", "configured, not yet polled")
        XCTAssertTrue(model.diagram.lanes.isEmpty, "no snapshot, no lanes")

        fleet.service = nil
        XCTAssertEqual(model.diagramPlaceholder, "Needs setup — open the Setup tab")

        fleet.service = fake
        fleet.status = FleetStatus()
        XCTAssertNil(model.diagramPlaceholder, "a polled status draws lanes, not the headline")
        XCTAssertEqual(model.diagram.lanes.map(\.id), [.tart], "the diagram reads the same snapshot")
        XCTAssertTrue(model.diagram.lanes[0].isIdle)
    }

    func testStaleDaemonPlistNoticeAppearsInFleetTabStatusLine() {
        fleet.staleDaemonPlist =
            "the daemon LaunchAgent is installed but its binary is missing — run `kinhin daemon uninstall` to remove it"
        let line = models.fleetModel.statusLine
        XCTAssertTrue(line.contains("⚠"), "Fleet tab carries the stale-daemon warning: \(line)")
        XCTAssertTrue(line.contains("daemon uninstall"), "Fleet tab names the fix: \(line)")
    }

    func testStaleDaemonPlistNoticeDoesNotAppearWhenPlistIsClean() {
        fleet.staleDaemonPlist = nil
        let line = models.fleetModel.statusLine
        XCTAssertFalse(line.contains("⚠"), "no stale-daemon warning when the plist is clean: \(line)")
    }

    // MARK: - Buttons drive the controller

    private func calls(_ name: String) -> Int { fake.calls.filter { $0 == name }.count }

    func testStartAndStopButtonsReachTheBackend() async {
        models.fleetModel.startClicked()
        await waitUntil("start") { calls("start") == 1 }
        await waitUntil("pending clears") { fleet.pendingFleetAction == nil }

        models.fleetModel.stopClicked()
        await waitUntil("stop") { calls("stop") == 1 }
        await waitUntil("pending clears") { fleet.pendingFleetAction == nil }
    }

    func testStartWithNothingConfiguredOpensSetupInsteadOfStalling() {
        fleet.service = nil
        var openedSetup = 0
        models.fleetModel.onNeedsSetup = { openedSetup += 1 }
        models.fleetModel.startClicked()
        XCTAssertEqual(openedSetup, 1)
        XCTAssertNil(fleet.pendingFleetAction, "the button must not stay busy with no backend")
    }

    // MARK: - In-flight start/stop (progress + disabled controls)

    func testStartClickMarksPendingUntilTheActionEnds() async {
        fake.gated = true
        models.fleetModel.startClicked()
        XCTAssertEqual(models.fleetModel.pendingAction, .start)
        XCTAssertTrue(models.fleetModel.isBusy)
        await waitUntil("the click dispatches") { calls("start") == 1 }

        // The controller clears it when the command and refresh are done.
        fake.releaseGate()
        await waitUntil("pending clears") { fleet.pendingFleetAction == nil }
        XCTAssertFalse(models.fleetModel.isBusy)
    }

    func testStopClickMarksPendingAndIgnoresDoubleClicks() async {
        fake.gated = true
        fleet.status = {
            var s = FleetStatus(); s.running = true; return s
        }()
        models.fleetModel.stopClicked()
        XCTAssertEqual(models.fleetModel.pendingAction, .stop)
        await waitUntil("stop dispatched") { calls("stop") == 1 }

        // A second click while busy must not dispatch again (state backstop
        // behind the disabled buttons).
        models.fleetModel.stopClicked()
        models.fleetModel.startClicked()
        XCTAssertEqual(calls("stop"), 1)
        XCTAssertEqual(calls("start"), 0)

        fake.releaseGate()
        await waitUntil("pending clears") { fleet.pendingFleetAction == nil }
    }

    func testPauseToggleIsIgnoredWhileBusy() async {
        fake.gated = true
        fleet.status = FleetStatus()  // not paused, not busy
        models.fleetModel.startClicked()
        models.fleetModel.togglePause()
        XCTAssertEqual(calls("setPaused(true)"), 0, "no pause/resume during a start/stop")

        fake.releaseGate()
        await waitUntil("pending clears") { fleet.pendingFleetAction == nil }
        models.fleetModel.togglePause()
        await waitUntil("pause dispatched") { calls("setPaused(true)") == 1 }
    }

    func testPauseButtonDispatchesBasedOnRenderedState() async {
        fleet.status = FleetStatus()  // not paused
        models.fleetModel.togglePause()
        await waitUntil("pause") { calls("setPaused(true)") == 1 }

        var status = FleetStatus()
        status.paused = true
        fleet.status = status
        models.fleetModel.togglePause()
        await waitUntil("resume") { calls("setPaused(false)") == 1 }
        XCTAssertEqual(calls("setPaused(true)"), 1)
    }

    func testUpdateCardButtonChecksWhenNothingIsWaiting() {
        tabs.showAdvanced(.app)
        XCTAssertEqual(models.appModel.updateButtonTitle, "Check for Updates…")
        XCTAssertTrue(models.appModel.updateButtonEnabled)
    }

    func testUpdateCardRendersEachState() {
        tabs.showAdvanced(.app)
        let model = models.appModel
        updates.updateCardState = .checking
        XCTAssertFalse(model.updateButtonEnabled)
        XCTAssertTrue(model.updateText.contains("checking…"))

        updates.updateCardState = .available(version: "9.9.9")
        XCTAssertEqual(model.updateButtonTitle, "Install Update…")
        XCTAssertTrue(model.updateText.contains("Update available — kinhin 9.9.9"))

        updates.updateCardState = .upToDate(lastChecked: nil)
        XCTAssertTrue(model.updateText.contains("is up to date"))
        XCTAssertTrue(model.updateButtonEnabled)

        updates.updateCardState = .failed("offline")
        XCTAssertTrue(model.updateText.contains("Update check failed: offline"))
    }

    func testAppSectionShowsStaleDaemonNotice() {
        tabs.showAdvanced(.app)
        models.appModel.fleetController = fleet
        fleet.staleDaemonPlist =
            "the daemon LaunchAgent is installed but its binary is missing — run `kinhin daemon uninstall` to remove it"
        XCTAssertNotNil(models.appModel.daemonNotice, "App section reflects the stale-daemon notice")
        XCTAssertTrue(models.appModel.daemonNotice!.contains("daemon uninstall"))
    }

    func testAppSectionHidesDaemonNoticeWhenPlistIsClean() {
        tabs.showAdvanced(.app)
        models.appModel.fleetController = fleet
        fleet.staleDaemonPlist = nil
        XCTAssertNil(models.appModel.daemonNotice, "App section hides the notice when there is no stale plist")
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

    func testDeleteButtonConfirmsThenDeletesTheVM() async {
        AlertKit.runModal = { _ in .alertFirstButtonReturn }
        defer { AlertKit.runModal = { $0.runModal() } }
        var record = VMRecord(id: "kinhin-vm-del", phase: .ready)
        record.createdAt = Date()
        fake.status = FleetStatus(records: [record])
        fleet.status = fake.status
        models.fleetModel.deleteClicked("kinhin-vm-del")
        await waitUntil("delete") { fake.calls.contains("deleteVM(kinhin-vm-del)") }
    }

    func testDeclinedDeleteConfirmationLeavesTheVMAlone() async {
        AlertKit.runModal = { _ in .alertSecondButtonReturn }
        defer { AlertKit.runModal = { $0.runModal() } }
        models.fleetModel.deleteClicked("kinhin-vm-del")
        try? await Task.sleep(for: .milliseconds(50))
        XCTAssertFalse(fake.calls.contains("deleteVM(kinhin-vm-del)"))
    }

    func testFleetStatusFooterShowsTheStaleWarning() {
        let dir = FileManager.default.temporaryDirectory
        let cfgURL = dir.appendingPathComponent("kinhin-footer-test-\(UUID().uuidString).yaml")
        let config = "accounts:\n  - name: github\n    forge: github\n    scope: \"your-org/your-repo\"\nlabels: [a]\n"
        try? config.write(to: cfgURL, atomically: true, encoding: .utf8)
        let cfg = try! ConfigLoader.load(from: cfgURL)
        let engine = FleetEngine(
            config: cfg, github: FakeGitHub(), tart: FakeTart(), store: makeTestStore(), ssh: FakeSSH(), host: testHost)
        fleet.service = nil
        fleet.backend = .inProcess(engine)
        let footer = models.fleetModel.fleetStatusFooter
        // The mode lives in the fleet badge, not the footer; without a
        // warning the footer has nothing to show.
        XCTAssertTrue(footer.isEmpty)

        fleet.staleDaemonPlist =
            "the daemon LaunchAgent is installed but its binary is missing — run `kinhin daemon uninstall` to remove it"
        let footerWithWarning = models.fleetModel.fleetStatusFooter
        XCTAssertEqual(
            footerWithWarning.map(\.text),
            [
                "the daemon LaunchAgent is installed but its binary is missing — run `kinhin daemon uninstall` to remove it"
            ])
        XCTAssertEqual(footerWithWarning.map(\.style), [.warn])
        try? FileManager.default.removeItem(at: cfgURL)
    }

    func testFleetStatusFooterShowsAppProblemsAsErrors() {
        fleet.setProblem(.configPush, "config not applied")
        fleet.setProblem(.launch, "didn't start at launch")
        let footer = models.fleetModel.fleetStatusFooter
        XCTAssertEqual(footer.map(\.text), ["didn't start at launch", "config not applied"], "launch first")
        XCTAssertEqual(footer.map(\.style), [.error, .error])
    }

    func testFleetStatusFooterIsEmptyWhenNoBackend() {
        fleet.service = nil
        let footer = models.fleetModel.fleetStatusFooter
        XCTAssertTrue(footer.isEmpty, "no mode, no stale warning when nothing is running")
    }

    func testFleetModeBadgeShowsWhenBackendIsAttached() {
        let dir = FileManager.default.temporaryDirectory
        let cfgURL = dir.appendingPathComponent("kinhin-badge-test-\(UUID().uuidString).yaml")
        let config = "accounts:\n  - name: github\n    forge: github\n    scope: \"your-org/your-repo\"\nlabels: [a]\n"
        try? config.write(to: cfgURL, atomically: true, encoding: .utf8)
        let cfg = try! ConfigLoader.load(from: cfgURL)
        let engine = FleetEngine(
            config: cfg, github: FakeGitHub(), tart: FakeTart(), store: makeTestStore(), ssh: FakeSSH(), host: testHost)
        fleet.service = nil
        fleet.backend = .inProcess(engine)
        XCTAssertEqual(models.fleetModel.fleetModeBadge, "in-process engine")
        try? FileManager.default.removeItem(at: cfgURL)
    }

    func testFleetModeBadgeIsHiddenWhenNoBackend() {
        fleet.service = nil
        XCTAssertNil(models.fleetModel.fleetModeBadge, "no badge when nothing is running")
    }
}
