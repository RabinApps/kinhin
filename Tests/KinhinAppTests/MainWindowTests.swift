import XCTest
import AppKit
import KinhinKit
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

    override func setUp() {
        super.setUp()
        suiteName = "kinhin-tests.mainwindow-\(UUID().uuidString)"
        suite = UserDefaults(suiteName: suiteName)
        delegate = RecordingTabsDelegate()
        window = MainTabsWindowController(defaults: suite)
        window.delegate = delegate
    }

    override func tearDown() {
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
        XCTAssertFalse(shouldQuitOnMainWindowClose(launchMode: .mainWindowAndMenuBar),
                       "menu bar must keep running when the window closes")
        XCTAssertFalse(shouldQuitOnMainWindowClose(launchMode: .menuBarOnly))
        XCTAssertTrue(shouldQuitOnMainWindowClose(launchMode: .mainWindowOnly),
                      "without the menu bar, closing the window is quitting the app")
    }

    // MARK: tab structure

    func testFourTabsInDisplayOrder() {
        XCTAssertEqual(MainTab.allCases, [.fleet, .runtimes, .tokens, .settings, .logs])
        XCTAssertEqual(MainTab.allCases.map(\.label), ["Fleet", "Runtimes", "Tokens", "Settings", "Logs"])
    }

    func testWindowStartsOnTheFleetTab() {
        XCTAssertEqual(window.selectedTab, .fleet)
        XCTAssertEqual(segment().selectedSegment, 0)
    }

    func testSelectingATabSwapsTheVisibleContent() {
        window.selectTab(.runtimes, notify: false)
        XCTAssertEqual(window.selectedTab, .runtimes)
        XCTAssertEqual(segment().selectedSegment, index(of: .runtimes))

        window.selectTab(.settings, notify: false)
        XCTAssertEqual(window.selectedTab, .settings)
        XCTAssertEqual(segment().selectedSegment, index(of: .settings))
    }

    func testSegmentClickSwitchesTabs() {
        let control = segment()
        control.selectedSegment = index(of: .tokens)
        fire(control)
        XCTAssertEqual(window.selectedTab, .tokens)
    }

    func testSetupIsAnOverlayNotATab() {
        window.showSetupOverlay()
        XCTAssertEqual(window.selectedTab, .fleet, "the underlying tab does not change")
        XCTAssertFalse(segment().isEnabled, "segment control disabled while onboarding owns the window")
        XCTAssertNotNil(window.setupController, "the overlay embeds the checklist")

        // Setup finishing hands the window back to the tabs.
        finishSetupForTesting()
        XCTAssertTrue(segment().isEnabled)
        XCTAssertEqual(window.selectedTab, .fleet)
        XCTAssertEqual(delegate.setupFinishedCalls, 1, "the delegate re-bootstraps the engine")
    }

    func testSetupIncompleteOpensTheOverlayWhenTheWindowOpens() {
        window.setupIncompleteFlag = true
        window.applySetupInProgress()
        XCTAssertNotNil(window.setupController)
        XCTAssertFalse(segment().isEnabled)

        finishSetupForTesting()
        XCTAssertTrue(segment().isEnabled)
    }

    func testEmbeddedChildControllersExistForTheirTabs() {
        window.selectTab(.runtimes, notify: false)
        window.selectTab(.tokens, notify: false)
        window.selectTab(.logs, notify: false)
        XCTAssertNotNil(window.runtimesController, "the Runtimes tab embeds the pane")
        XCTAssertNotNil(window.tokenController, "the Tokens tab embeds the form")
        XCTAssertNotNil(window.logsController, "the Logs tab embeds the viewer")
    }

    // MARK: Fleet tab rendering

    func testRenderShowsNeedsSetupBeforeFirstStatus() {
        window.render(status: nil)
        XCTAssertTrue(allText().contains("Needs setup — open the Setup tab"), "got: \(allText())")
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
        status.records = [busy, {
            var ready = VMRecord(id: "kinhin-vm-idle", phase: .ready)
            ready.createdAt = Date()
            return ready
        }()]

        window.render(status: status)

        // The exact same line the menu renders — one renderer, two surfaces.
        XCTAssertTrue(allText().contains(AppDelegate.statusLineText(for: status)), "got: \(allText())")
        XCTAssertTrue(allText().contains("kinhin-vm-test"), "got: \(allText())")
        XCTAssertTrue(allText().contains("busy"))
        XCTAssertTrue(allText().contains("2 repos"))
        XCTAssertEqual(deleteButtons().count, 2, "one Delete button per VM row")
        // Current-jobs section: only the record carrying a job, with repo.
        XCTAssertTrue(allText().contains("build — alpha/one, beta/two"), "current jobs list the workflow + repo: \(allText())")
        XCTAssertTrue(allText().contains("No jobs running.") == false)
    }

    func testRenderIdleFleetShowsNoVMsAndNoJobs() {
        window.render(status: FleetStatus())
        XCTAssertTrue(allText().contains("No VMs — the fleet is idle."))
        XCTAssertTrue(allText().contains("No jobs running."))
    }

    func testRenderTogglesPauseButtonTitle() {
        window.render(status: FleetStatus())
        XCTAssertEqual(pauseButton?.title, "Pause")

        var status = FleetStatus()
        status.running = true
        status.paused = true
        window.render(status: status)
        XCTAssertEqual(pauseButton?.title, "Resume")
    }

    func testRenderMarksErrorRows() {
        var failed = VMRecord(id: "kinhin-vm-err", phase: .failed)
        failed.createdAt = Date()
        failed.error = "boot timed out"
        window.render(status: FleetStatus(records: [failed]))
        XCTAssertTrue(allText().contains("⚠︎ boot timed out"))
    }

    // MARK: Settings tab

    func testSettingsPopupSyncsFromStoredModeWithoutNotifying() {
        // The Settings tab (and its popup) must exist first.
        window.selectTab(.settings, notify: false)
        // Init applied the stored (default) mode; the delegate must not have
        // been called back — no re-persist loop at construction time.
        XCTAssertEqual(selectedPopupIndex(), 0)
        XCTAssertTrue(allText().contains("menu bar"), "default subtitle describes the combined mode")
        XCTAssertTrue(delegate.changedModes.isEmpty)
    }

    func testChoosingAModeUpdatesTheCardAndNotifiesTheDelegate() {
        // The Settings tab (and its popup) must exist first.
        window.selectTab(.settings, notify: false)
        window.applyLaunchMode(.menuBarOnly)
        XCTAssertEqual(delegate.changedModes, [.menuBarOnly])
        XCTAssertEqual(selectedPopupIndex(), index(of: .menuBarOnly))

        window.applyLaunchMode(.mainWindowOnly)
        XCTAssertEqual(delegate.changedModes, [.menuBarOnly, .mainWindowOnly])
        XCTAssertEqual(selectedPopupIndex(), index(of: .mainWindowOnly))
        XCTAssertTrue(allText().contains("no menu bar item"), "subtitle tracks the picked mode")
    }

    func testChosenModePersistsToTheInjectedDefaults() {
        window.applyLaunchMode(.mainWindowOnly)
        XCTAssertEqual(AppPreferences.launchMode(in: suite), .mainWindowOnly,
                       "the choice must survive a relaunch via the injected suite")
        window.applyLaunchMode(.menuBarOnly)
        XCTAssertEqual(AppPreferences.launchMode(in: suite), .menuBarOnly)
    }

    func testLoginCheckboxPersistsAndNotifies() {
        window.selectTab(.settings, notify: false)
        loginCheck().state = .on
        fire(loginCheck())
        XCTAssertEqual(delegate.loginToggles, [true])
        XCTAssertTrue(AppPreferences.launchAtLogin(in: suite))

        loginCheck().state = .off
        fire(loginCheck())
        XCTAssertEqual(delegate.loginToggles, [true, false])
        XCTAssertFalse(AppPreferences.launchAtLogin(in: suite))
    }

    // MARK: delegate plumbing

    func testFleetControlButtonsReachTheDelegate() {
        fire(button(titled: "Start"))
        fire(button(titled: "Stop"))
        XCTAssertEqual(delegate.startCalls, 1)
        XCTAssertEqual(delegate.stopCalls, 1)
    }

    func testPauseButtonDispatchesBasedOnRenderedState() {
        window.render(status: FleetStatus()) // not paused
        fire(pauseButton)
        XCTAssertEqual(delegate.pauseCalls, 1)
        XCTAssertEqual(delegate.resumeCalls, 0)

        var status = FleetStatus()
        status.paused = true
        window.render(status: status)
        fire(pauseButton)
        XCTAssertEqual(delegate.pauseCalls, 1)
        XCTAssertEqual(delegate.resumeCalls, 1)
    }

    func testSecondaryButtonsReachTheDelegate() {
        fire(button(titled: "Open Logs Folder"))
        fire(button(titled: "Check for Updates…"))
        XCTAssertEqual(delegate.logsCalls, 1)
        XCTAssertEqual(delegate.updateCalls, 1)
    }

    func testLogsTabRendersSearchableViewer() {
        window.selectTab(.logs, notify: false)
        let vc = window.logsController!
        // The search field's placeholder (stringValue stays empty until typing).
        let searchFields = vc.view.flattenedViews().compactMap { $0 as? NSSearchField }
        XCTAssertEqual(searchFields.count, 1, "the Logs tab carries one search field")
        XCTAssertTrue(searchFields[0].placeholderString?.contains("Search logs") ?? false)
        // Level filter popup + line count (the popup's selected title lives
        // on the control, not in a text label).
        let popups = vc.view.flattenedViews().compactMap { $0 as? NSPopUpButton }
        XCTAssertEqual(popups.count, 1)
        XCTAssertEqual(popups[0].titleOfSelectedItem, "All", "level filter present, defaulting to All")
        XCTAssertTrue(allText().contains("lines"), "a line count is shown: \(allText())")
        // The text area exists and shows the empty state.
        XCTAssertNotNil(vc.view.flattenedViews().compactMap { $0 as? NSTextView }.first)
    }

    func testDeleteButtonCarriesTheVMID() {
        var record = VMRecord(id: "kinhin-vm-del", phase: .ready)
        record.createdAt = Date()
        window.render(status: FleetStatus(records: [record]))

        guard let button = deleteButtons().first else {
            return XCTFail("expected a Delete button on the VM row")
        }
        fire(button)
        XCTAssertEqual(delegate.deletedVMIDs, ["kinhin-vm-del"])
    }

    // MARK: diagnostics sheet

    /// Presents the diagnostics sheet the same way the Fleet tab's button
    /// does (beginSheet on the main window) but with a fixture report —
    /// never the live doctor probe, which would subprocess-spam the host.
    @discardableResult
    private func presentDiagnosticsSheet(withFixture fixture: Data) throws -> DiagnosticsViewController {
        let controller = DiagnosticsViewController()
        let sheet = NSWindow(contentViewController: controller)
        sheet.styleMask = [.titled]
        sheet.title = "Diagnostics"
        window.window!.beginSheet(sheet) { _ in }
        // Attachment completes on the run loop — spin until sheetParent is
        // set so Close (endSheet) is driven the way a real click sees it.
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        controller.render(try JSONDecoder().decode(DoctorReport.self, from: fixture))
        sheet.layoutIfNeeded()
        return controller
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
        let controller = try presentDiagnosticsSheet(withFixture: doctorFixture())
        defer { controller.view.removeFromSuperview() }

        let sheet = try XCTUnwrap(controller.view.window, "the sheet is attached")
        XCTAssertNotNil(sheet.sheetParent, "presented as a sheet on the main window")

        // Regression: the report stack is the scroll view's document and has
        // no intrinsic frame — unpinned it collapsed to 0x0 and rendered
        // nothing. After layout it must span the viewport.
        let stack = try XCTUnwrap(
            controller.view.flattenedViews().compactMap { $0 as? NSScrollView }.first?.documentView as? NSStackView
        )
        XCTAssertGreaterThan(stack.frame.width, 300, "document stack must span the clip view, got \(stack.frame)")

        let text = sheet.contentView!.flattenedText().joined(separator: "\n")
        XCTAssertTrue(text.contains("Host"))
        XCTAssertTrue(text.contains("Command Line Tools"))
        XCTAssertTrue(text.contains("Tart (macOS VMs)"))
        XCTAssertTrue(text.contains("Apple container (Linux)"))
        XCTAssertTrue(text.contains("Toolchain cache"))
        XCTAssertTrue(text.contains("Capacity"))
    }

    func testDiagnosticsCloseEndsTheSheet() throws {
        let controller = try presentDiagnosticsSheet(withFixture: doctorFixture())
        let sheet = try XCTUnwrap(controller.view.window)

        // Regression: dismiss(_:) is a no-op for beginSheet presentation —
        // only the parent's endSheet(_) ends a sheet, so Close did nothing.
        guard let close = controller.view.flattenedButtons().first(where: { $0.title == "Close" }) else {
            return XCTFail("the sheet carries a Close button")
        }
        fire(close)
        // endSheet detaches after the sheet's exit animation completes on
        // the run loop — spin it so the detach is observed. Detachment is
        // measured on the sheet window itself: the controller's view stays
        // installed inside the hidden sheet window (so it can re-open),
        // meaning view.window is never nil.
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        XCTAssertNil(sheet.sheetParent, "Close must detach the sheet from its parent")
        XCTAssertFalse(sheet.isVisible, "Close must hide the sheet")
    }

    func testDiagnosticsRefreshOnlyWhenVisible() {
        // No window → the poll-loop refresh is a no-op (never probes).
        let idle = DiagnosticsViewController()
        XCTAssertFalse(idle.isViewLoaded)

        let controller = DiagnosticsViewController()
        let sheet = NSWindow(contentViewController: controller)
        sheet.styleMask = [.titled]
        window.window!.beginSheet(sheet) { _ in }
        XCTAssertTrue(controller.isViewLoaded)
        XCTAssertNotNil(controller.view.window)
    }

    // MARK: helpers

    private func segment() -> NSSegmentedControl {
        guard let control = window.window?.contentView?.flattenedViews().compactMap({ $0 as? NSSegmentedControl }).first else {
            fatalError("main window must carry the tab segment control")
        }
        return control
    }

    private func loginCheck() -> NSButton {
        guard let button = window.window?.contentView?.flattenedButtons().first(where: { $0.title.contains("Launch kinhin at login") }) else {
            fatalError("Settings tab must carry the login checkbox")
        }
        return button
    }

    private func index(of tab: MainTab) -> Int {
        MainTab.allCases.firstIndex(of: tab) ?? -1
    }

    /// Drives the checklist's Start Fleet → onFinished → dismiss path.
    private func finishSetupForTesting() {
        window.setupController?.onFinished?()
    }

    private func index(of mode: LaunchMode) -> Int {
        LaunchMode.allCases.firstIndex(of: mode) ?? -1
    }

    private func allText() -> String {
        window.window?.contentView?.flattenedText().joined(separator: "\n") ?? ""
    }

    private var pauseButton: NSButton? {
        window.window?.contentView?.flattenedButtons().first { $0.title == "Pause" || $0.title == "Resume" }
    }

    private func button(titled title: String) -> NSButton? {
        window.window?.contentView?.flattenedButtons().first { $0.title == title }
    }

    private func deleteButtons() -> [NSButton] {
        window.window?.contentView?.flattenedButtons().filter { $0.title == "Delete" } ?? []
    }

    private func popups() -> [NSPopUpButton] {
        window.window?.contentView?.flattenedViews().compactMap { $0 as? NSPopUpButton } ?? []
    }

    private func selectedPopupIndex() -> Int {
        let all = popups()
        XCTAssertEqual(all.count, 1, "exactly one launch-mode popup (Settings tab)")
        return all.first?.indexOfSelectedItem ?? -1
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
