import AppKit
import SwiftUI
import XCTest

@testable import KinhinKit
@testable import kinhin_app

/// Records MainTabsWindowDelegate calls so window actions can be tested
/// without touching a real engine, daemon, or NSApp.terminate.
@MainActor
private final class RecordingTabsDelegate: MainTabsWindowDelegate {
    var startCalls = 0
    var stopCalls = 0
    var pauseCalls = 0
    var resumeCalls = 0
    var deletedVMIDs: [String] = []
    var logsCalls = 0
    var updateCalls = 0
    var changedModes: [LaunchMode] = []
    var loginToggles: [Bool] = []
    var closeCalls = 0
    var setupFinishedCalls = 0
    var rebootstrapCalls = 0

    func startFleet() { startCalls += 1 }
    func stopFleet() { stopCalls += 1 }
    func pauseFleet() { pauseCalls += 1 }
    func resumeFleet() { resumeCalls += 1 }
    func deleteVM(id: String) { deletedVMIDs.append(id) }
    func openLogsFolder() { logsCalls += 1 }
    func checkForUpdatesNow() { updateCalls += 1 }
    var updateCardState: UpdateCardState = .idle(lastChecked: nil)
    func launchModeChanged(_ mode: LaunchMode) { changedModes.append(mode) }
    func launchAtLoginChanged(_ enabled: Bool) { loginToggles.append(enabled) }
    func mainTabsWindowWillClose() { closeCalls += 1 }
    func setupTabFinished() { setupFinishedCalls += 1; rebootstrapCalls += 1 }
}

@MainActor
final class MainWindowTests: XCTestCase {
    private var delegate: RecordingTabsDelegate!
    private var window: MainTabsWindowController!
    private var suite: UserDefaults!
    private var suiteName: String!
    private var scratchConfig: URL!

    override func setUp() {
        super.setUp()
        suiteName = "kinhin-tests.mainwindow-\(UUID().uuidString)"
        suite = UserDefaults(suiteName: suiteName)
        delegate = RecordingTabsDelegate()
        scratchConfig = FileManager.default.temporaryDirectory.appendingPathComponent(
            "kinhin-mainwindow-\(UUID().uuidString).yaml")
        try? "repo: \"your-org/your-repo\"\nlabels: [a]\n".write(to: scratchConfig, atomically: true, encoding: .utf8)
        window = MainTabsWindowController(defaults: suite)
        window.delegate = delegate
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: scratchConfig)
        suite.removePersistentDomain(forName: suiteName)
        window = nil
        delegate = nil
        suite = nil
        suiteName = nil
        super.tearDown()
    }

    // MARK: pure decisions

    func testActivationPolicyTracksMainWindowVisibility() {
        // A visible main window is always a regular app, in every mode.
        for mode in LaunchMode.allCases {
            XCTAssertEqual(activationPolicy(showingMainWindow: true, launchMode: mode), .regular)
        }
        // Window-centric modes stay regular even while the window is closed
        // (Dock re-open feels like a normal app).
        XCTAssertEqual(activationPolicy(showingMainWindow: false, launchMode: .mainWindowAndMenuBar), .regular)
        XCTAssertEqual(activationPolicy(showingMainWindow: false, launchMode: .mainWindowOnly), .regular)
        // Menu-bar-only is the classic accessory app.
        XCTAssertEqual(activationPolicy(showingMainWindow: false, launchMode: .menuBarOnly), .accessory)
    }

    func testQuitOnMainWindowCloseOnlyInMainWindowOnlyMode() {
        XCTAssertFalse(
            shouldQuitOnMainWindowClose(launchMode: .mainWindowAndMenuBar),
            "menu bar must keep running when the window closes")
        XCTAssertFalse(shouldQuitOnMainWindowClose(launchMode: .menuBarOnly))
        XCTAssertTrue(
            shouldQuitOnMainWindowClose(launchMode: .mainWindowOnly),
            "without the menu bar, closing the window is quitting the app")
    }

    // MARK: tab structure

    func testTabsAndAdvancedSectionsInDisplayOrder() {
        XCTAssertEqual(MainTab.allCases, [.fleet, .setup, .advanced])
        XCTAssertEqual(
            AdvancedSection.allCases.map(\.label),
            ["Accounts", "Capacity", "Routing", "Containers", "Toolchains", "App"])
    }

    func testSetupTabOnlyExistsWhileSetupIsUnfinished() {
        XCTAssertEqual(window.visibleTabs, [.fleet, .advanced], "a configured app has no Setup tab")
        XCTAssertEqual(segment().segmentCount, 2)
        XCTAssertEqual(
            (0..<segment().segmentCount).map { segment().label(forSegment: $0) ?? "" }, ["Fleet", "Advanced"])

        window.setupIncompleteFlag = true
        XCTAssertEqual(window.visibleTabs, [.fleet, .setup, .advanced])
        XCTAssertEqual(segment().segmentCount, 3)
        XCTAssertEqual(segment().label(forSegment: 1), "Setup")

        window.setupIncompleteFlag = false
        XCTAssertEqual(segment().segmentCount, 2, "finishing setup removes the tab")
    }

    func testWindowStartsOnTheFleetTab() {
        XCTAssertEqual(window.selectedTab, .fleet)
        XCTAssertEqual(segment().selectedSegment, 0)
    }

    func testSelectingATabSwapsTheVisibleContent() {
        window.selectTab(.advanced, notify: false)
        XCTAssertEqual(window.selectedTab, .advanced)
        XCTAssertEqual(segment().selectedSegment, index(of: .advanced))
        window.selectTab(.fleet, notify: false)
        XCTAssertEqual(window.selectedTab, .fleet)
        XCTAssertEqual(segment().selectedSegment, index(of: .fleet))
    }

    func testSegmentClickSwitchesTabs() {
        let control = segment()
        control.selectedSegment = index(of: .advanced)
        fire(control)
        XCTAssertEqual(window.selectedTab, .advanced)
    }

    func testSetupTabStaysNavigableDuringOnboardingAndVanishesWhenDone() {
        window.setupIncompleteFlag = true
        window.showSetup()
        XCTAssertEqual(window.selectedTab, .setup)
        XCTAssertTrue(segment().isEnabled, "the tab bar is never locked out")
        XCTAssertNotNil(window.wizardModel, "first run shows the guided wizard")

        // Finishing removes the Setup tab and hands the window to Fleet.
        finishSetupForTesting()
        XCTAssertEqual(window.selectedTab, .fleet)
        XCTAssertEqual(window.visibleTabs, [.fleet, .advanced])
        XCTAssertNil(window.wizardModel)
        XCTAssertEqual(delegate.setupFinishedCalls, 1, "the delegate re-bootstraps the engine")
    }

    func testFinishLaterKeepsTheSetupTab() {
        let wizard = showWizard()
        wizard.next()  // connect → mac
        wizard.next()  // mac → toolchains
        wizard.next()  // toolchains → start
        wizard.skip()  // "Finish later" on start step
        XCTAssertEqual(window.selectedTab, .fleet)
        XCTAssertEqual(window.visibleTabs, [.fleet, .setup, .advanced], "unfinished setup stays reachable")
    }

    func testSetupIncompleteOpensTheWizardWhenTheWindowOpens() {
        window.setupIncompleteFlag = true
        window.applySetupInProgress()
        XCTAssertEqual(window.selectedTab, .setup)
        XCTAssertNotNil(window.wizardModel)
    }

    func testAfterSetupAccountsLiveInAdvanced() {
        window.tokenProbe = { _ in false }
        window.setupIncompleteFlag = false
        window.showSetup()  // menu "Setup…" after onboarding lands here
        XCTAssertEqual(window.selectedTab, .advanced)
        XCTAssertEqual(window.selectedAdvancedSection, .accounts)
        XCTAssertNil(window.wizardModel)
        XCTAssertNotNil(window.connectModel)
        XCTAssertNotNil(window.macToolsModel)
        let page = window.advancedContainer.subviews.first
        XCTAssertTrue(page is NSHostingView<AccountsSectionView>, "the Accounts page hosts the SwiftUI forms")
        XCTAssertNotNil(page?.window, "and it is installed in the window")
    }

    func testWizardWalksFourSteps() {
        let wizard = showWizard()
        XCTAssertEqual(wizard.step, .connect, "the wizard opens on connecting an account")

        wizard.next()  // connect → mac
        XCTAssertEqual(wizard.step, .mac)
        wizard.next()  // mac → toolchains
        XCTAssertEqual(wizard.step, .toolchains)
        wizard.next()  // toolchains → start
        XCTAssertEqual(wizard.step, .start)
    }

    func testWizardCannotStartUntilConnectedAndReady() {
        let wizard = showWizard()
        wizard.next()  // connect → mac
        wizard.next()  // mac → toolchains
        wizard.next()  // toolchains → start
        XCTAssertEqual(wizard.step, .start)
        // Nothing connected in a hermetic test: pressing Start must not
        // finish (it would bounce the app straight back into setup).
        wizard.next()
        XCTAssertEqual(delegate.setupFinishedCalls, 0)
        XCTAssertTrue(
            wizard.summaryText.contains("Still needed"),
            "the summary says what is missing: \(wizard.summaryText)")
    }

    func testWizardBackNavigation() {
        let wizard = showWizard()
        wizard.next()
        wizard.next()  // mac → start
        wizard.back()
        XCTAssertEqual(wizard.step, .mac)
        wizard.back()
        XCTAssertEqual(wizard.step, .connect)
    }

    func testAdvancedCapacityHostsTheLoadedForm() {
        window.showAdvanced(.capacity)
        XCTAssertEqual(window.selectedAdvancedSection, .capacity)
        XCTAssertNotNil(window.capacityModel, "Capacity embeds the form model")
        XCTAssertTrue(window.advancedContainer.subviews.first is NSHostingView<CapacityView>)
        XCTAssertFalse(allText().contains("Forges"), "accounts live in the Accounts section")
    }

    func testAdvancedSectionsEmbedTheirControllers() {
        window.showAdvanced(.routing)
        XCTAssertNotNil(window.runtimesModel, "Routing embeds the runtimes pane")
        window.showAdvanced(.app)
        XCTAssertEqual(window.selectedAdvancedSection, .app)
        XCTAssertTrue(
            window.advancedContainer.subviews.first is NSHostingView<AppSectionView>, "App hosts the SwiftUI section")
    }

    // MARK: Fleet tab rendering

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
        XCTAssertEqual(model.statusLine, AppDelegate.statusLineText(for: status))
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

    func testRenderMarksErrorRows() {
        var failed = VMRecord(id: "kinhin-vm-err", phase: .failed)
        failed.createdAt = Date()
        failed.error = "boot timed out"
        window.render(status: FleetStatus(records: [failed]))
        XCTAssertTrue(window.fleetModel.detail(for: failed).contains("⚠︎ boot timed out"))
    }

    // MARK: Settings tab

    func testLaunchModeSyncsFromStoredModeWithoutNotifying() {
        // The App section must exist first.
        window.showAdvanced(.app)
        // Init read the stored (default) mode; the delegate must not have
        // been called back — no re-persist loop at construction time.
        XCTAssertEqual(window.appModel.launchMode, .mainWindowAndMenuBar)
        XCTAssertTrue(window.appModel.launchMode.subtitle.contains("menu bar"))
        XCTAssertTrue(delegate.changedModes.isEmpty)
        XCTAssertTrue(window.advancedContainer.subviews.first is NSHostingView<AppSectionView>)
    }

    func testChoosingAModeUpdatesTheCardAndNotifiesTheDelegate() {
        window.showAdvanced(.app)
        window.appModel.setLaunchMode(.menuBarOnly)
        XCTAssertEqual(delegate.changedModes, [.menuBarOnly])
        XCTAssertEqual(window.appModel.launchMode, .menuBarOnly)

        window.appModel.setLaunchMode(.mainWindowOnly)
        XCTAssertEqual(delegate.changedModes, [.menuBarOnly, .mainWindowOnly])
        XCTAssertEqual(window.appModel.launchMode, .mainWindowOnly)
        XCTAssertTrue(
            window.appModel.launchMode.subtitle.contains("no menu bar item"), "subtitle tracks the picked mode")
    }

    func testChosenModePersistsToTheInjectedDefaults() {
        window.appModel.setLaunchMode(.mainWindowOnly)
        XCTAssertEqual(
            AppPreferences.launchMode(in: suite), .mainWindowOnly,
            "the choice must survive a relaunch via the injected suite")
        window.appModel.setLaunchMode(.menuBarOnly)
        XCTAssertEqual(AppPreferences.launchMode(in: suite), .menuBarOnly)
    }

    func testLoginCheckboxPersistsAndNotifies() {
        window.showAdvanced(.app)
        window.appModel.setLaunchAtLogin(true)
        XCTAssertEqual(delegate.loginToggles, [true])
        XCTAssertTrue(AppPreferences.launchAtLogin(in: suite))

        window.appModel.setLaunchAtLogin(false)
        XCTAssertEqual(delegate.loginToggles, [true, false])
        XCTAssertFalse(AppPreferences.launchAtLogin(in: suite))
    }

    func testAutoStartCheckboxPersists() {
        window.showAdvanced(.app)
        XCTAssertFalse(window.appModel.autoStartFleet)
        window.appModel.setAutoStartFleet(true)
        XCTAssertTrue(AppPreferences.autoStartFleet(in: suite))
        window.appModel.setAutoStartFleet(false)
        XCTAssertFalse(AppPreferences.autoStartFleet(in: suite))
    }

    // MARK: delegate plumbing

    func testFleetControlButtonsReachTheDelegate() {
        window.fleetModel.onStart()
        window.fleetModel.onStop()
        XCTAssertEqual(delegate.startCalls, 1)
        XCTAssertEqual(delegate.stopCalls, 1)
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
        XCTAssertTrue(model.statusText.contains("lines"), "a line count is shown")
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

    // MARK: diagnostics sheet

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

    // MARK: helpers

    /// Opens the wizard with its forms pointed at a scratch config, so
    /// stepping through never touches (or auto-edits) the real one.
    private func showWizard() -> WizardModel {
        window.setupIncompleteFlag = true
        window.showSetup()
        let wizard = window.wizardModel!
        wizard.mac.configURL = scratchConfig
        wizard.connect.configURL = scratchConfig
        wizard.connect.hasStoredToken = { _ in false }
        wizard.mac.autoEnableLinuxRuntime = false
        return wizard
    }

    private func segment() -> NSSegmentedControl {
        guard let control = window.window?.contentView?.flattenedViews().compactMap({ $0 as? NSSegmentedControl }).first
        else {
            fatalError("main window must carry the tab segment control")
        }
        return control
    }

    private func index(of tab: MainTab) -> Int {
        window.visibleTabs.firstIndex(of: tab) ?? -1
    }

    /// Drives the wizard's Finish → onFinished → dismiss path.
    private func finishSetupForTesting() {
        window.wizardModel?.onFinished?()
    }

    private func allText() -> String {
        window.window?.contentView?.flattenedText().joined(separator: "\n") ?? ""
    }

    /// Fires a control's action the way a click would (target/action ignores
    /// method visibility, so private @objc actions stay reachable in tests).
    /// Named `fire` to stay clear of NSObject.perform(_:).
    private func fire(_ control: NSControl?, line: UInt = #line) {
        guard let control else { return XCTFail("control is nil", line: line) }
        guard let target = control.target else {
            return XCTFail("control has no target", line: line)
        }
        guard let action = control.action else {
            return XCTFail("control has no action", line: line)
        }
        _ = target.perform(action, with: control)
    }
}

extension NSView {
    /// All descendant views, depth-first.
    fileprivate func flattenedViews() -> [NSView] {
        var result: [NSView] = []
        for sub in subviews {
            result.append(sub)
            result.append(contentsOf: sub.flattenedViews())
        }
        return result
    }

    fileprivate func flattenedText() -> [String] {
        flattenedViews().compactMap { ($0 as? NSTextField)?.stringValue }
    }

    fileprivate func flattenedButtons() -> [NSButton] {
        flattenedViews().compactMap { $0 as? NSButton }
    }
}
