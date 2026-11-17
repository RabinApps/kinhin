import XCTest

@testable import KinhinKit
@testable import kinhin_app

/// Navigation rules behind the main window: the sidebar's sections, the Setup gate, lazy section building, the
/// Diagnostics panes and the sheets.
@MainActor
final class MainTabsModelTests: MainWindowTestCase {

    override func setUp() async throws {
        try await super.setUp()
        models.tokenProbe = { _ in false }  // never touch the Keychain
        stubHealthProbe(models)
    }

    /// A fixture report, so opening Diagnostics never runs the live doctor probe.
    private func stubHealthProbe(_ models: WindowModels) {
        let fixture = DoctorReportBuilder(
            host: HostResources(logicalCores: 8, memoryGB: 16, freeDiskGB: 100, arm64: true),
            clt: .ok(version: "26.0"), tartHealth: .healthy, tartList: [], config: .missing,
            authLoad: { _ in nil }, accountLoad: { _, _ in nil })
        models.ensureDiagnosticsModel().loadReport = { await fixture.build() }
    }

    // MARK: - Sections

    func testStartsOnFleetWithoutBuildingAnySection() {
        XCTAssertEqual(tabs.selectedSection, .fleet)
        XCTAssertNil(models.connectModel)
        XCTAssertNil(models.capacityModel)
        XCTAssertNil(models.wizardModel)
    }

    func testSidebarHoldsTheSixSectionsInOrderAndHidesWhileSetupGates() {
        XCTAssertEqual(
            tabs.visibleSections, [.fleet, .runtimes, .accounts, .toolchains, .diagnostics, .settings])
        fleet.setupIncomplete = true
        XCTAssertEqual(tabs.visibleSections, [], "no sidebar while setup gates the window")
        XCTAssertTrue(tabs.isGatedBySetup)
        tabs.setupIncomplete = false
        XCTAssertFalse(fleet.setupIncomplete, "the model writes through to the controller")
    }

    func testSelectingSetupAfterOnboardingLandsOnAccounts() {
        tabs.showSetup()
        XCTAssertEqual(tabs.selectedSection, .accounts)
        XCTAssertNil(models.wizardModel)
        XCTAssertNotNil(models.connectModel)
    }

    func testShowSetupKeepsAWizardThatIsAlreadyUp() throws {
        fleet.setupIncomplete = true
        tabs.showSetup()
        let first = try XCTUnwrap(models.wizardModel)
        tabs.select(.fleet)
        XCTAssertTrue(models.wizardModel === first, "a section request keeps the wizard's state")
        tabs.showSetup()
        XCTAssertTrue(models.wizardModel === first, "the menu's Setup… must not discard typed input")
    }

    func testWizardFinishHandsOffToTheAppAndLandsOnFleet() throws {
        fleet.setupIncomplete = true
        var finished = 0
        tabs.onSetupFinished = { finished += 1 }
        tabs.showSetup()
        try XCTUnwrap(models.wizardModel).onFinished?()

        XCTAssertEqual(finished, 1)
        XCTAssertEqual(tabs.selectedSection, .fleet)
        XCTAssertFalse(fleet.setupIncomplete)
        XCTAssertNil(models.wizardModel)
    }

    // MARK: - Setup gating

    func testGatedWindowIgnoresSectionRequestsAndAlwaysShowsTheWizard() {
        fleet.setupIncomplete = true
        tabs.select(.fleet)
        XCTAssertNotNil(models.wizardModel)
        tabs.userSelected(.runtimes)
        tabs.select(.settings)
        XCTAssertEqual(tabs.selectedSection, .fleet, "the requested section never changes behind the wizard")
        XCTAssertNil(models.runtimesModel, "no section is built behind the wizard")
        XCTAssertEqual(tabs.visibleSections, [])
    }

    func testGatedWindowIgnoresLogsAndDiagnosticsRequests() {
        fleet.setupIncomplete = true
        tabs.showDiagnostics(.logs)
        models.fleetModel.onShowLogs()
        models.fleetModel.onShowDiagnostics()
        models.fleetModel.onShowBenchmarks()
        XCTAssertNil(models.logsModel)
        XCTAssertNil(models.benchmarksModel)
        XCTAssertNotEqual(tabs.diagnosticsPane, .logs)
    }

    func testGatedWindowRefusesEverySheet() {
        fleet.setupIncomplete = true
        tabs.present(.sponsor)
        tabs.present(.workflowTest)
        tabs.present(.videos)
        tabs.present(.pipeline(vmID: "vm-1"))
        XCTAssertNil(tabs.sheet, "no sheets while first-run setup gates the window")
        XCTAssertNil(models.pipelineModel)
    }

    func testSidebarAppearsAndFleetOpensWhenTheWizardFinishes() throws {
        fleet.setupIncomplete = true
        tabs.showSetup()
        XCTAssertTrue(tabs.isGatedBySetup)
        try XCTUnwrap(models.wizardModel).onFinished?()
        XCTAssertFalse(tabs.isGatedBySetup)
        XCTAssertEqual(tabs.visibleSections.count, 6)
        XCTAssertEqual(tabs.selectedSection, .fleet)
        tabs.select(.settings)
        XCTAssertEqual(tabs.selectedSection, .settings, "navigation works again")
    }

    func testApplySetupInProgressOnlyActsDuringOnboarding() {
        tabs.applySetupInProgress()
        XCTAssertNil(models.wizardModel)
        fleet.setupIncomplete = true
        tabs.applySetupInProgress()
        XCTAssertNotNil(models.wizardModel)
    }

    func testFleetButtonForSetupOpensTheWizard() {
        fleet.setupIncomplete = true
        models.fleetModel.onNeedsSetup()
        XCTAssertNotNil(models.wizardModel)
    }

    func testOpenConfigButtonIsWiredThroughTheWindowController() {
        tabs.openConfig()
        XCTAssertEqual(delegate.openConfigCalls, 1, "the Setup footer button should reach the window delegate")
    }

    // MARK: - Deep links

    func testSettingsMenuItemOpensTheSettingsSection() {
        tabs.showSettings()
        XCTAssertEqual(tabs.selectedSection, .settings, "Settings… must land on Settings, not on a bare tab")
    }

    func testFleetFooterButtonsMapToDiagnosticsPanes() {
        models.fleetModel.onShowLogs()
        XCTAssertEqual(tabs.selectedSection, .diagnostics)
        XCTAssertEqual(tabs.diagnosticsPane, .logs)
        XCTAssertNotNil(models.logsModel)

        models.fleetModel.onShowBenchmarks()
        XCTAssertEqual(tabs.diagnosticsPane, .benchmarks)
        XCTAssertNotNil(models.benchmarksModel)

        models.fleetModel.onShowDiagnostics()
        XCTAssertEqual(tabs.diagnosticsPane, .health)
    }

    func testFleetToolButtonsPresentTheirSheets() {
        models.fleetModel.onShowWorkflowTest()
        XCTAssertEqual(tabs.sheet, .workflowTest)
        tabs.dismissSheet()
        models.fleetModel.onShowVideos()
        XCTAssertEqual(tabs.sheet, .videos)
    }

    // MARK: - Section building

    func testFirstVisitBuildsTheSectionAndCapacityIsNeverReloaded() {
        tabs.select(.runtimes)
        XCTAssertEqual(models.capacityModel?.loads, 1, "built and loaded once")
        tabs.select(.fleet)
        tabs.select(.runtimes)
        XCTAssertEqual(
            models.capacityModel?.loads, 1, "the capacity form is never reloaded: unapplied edits would be lost")
    }

    func testDataBackedSectionsReloadEveryTimeTheyAreShown() {
        tabs.select(.runtimes)
        let afterFirst = models.runtimesModel?.loads ?? 0
        tabs.select(.accounts)
        tabs.select(.runtimes)
        XCTAssertGreaterThan(models.runtimesModel?.loads ?? 0, afterFirst)
    }

    func testRefreshVisibleSectionNeverProbesOutsideItsSection() {
        tabs.refreshVisibleSection()
        XCTAssertNil(models.connectModel, "the Fleet refresh builds nothing")
        tabs.select(.runtimes)
        let loads = models.capacityModel?.loads
        tabs.refreshVisibleSection()
        XCTAssertGreaterThan(models.capacityModel?.loads ?? 0, loads ?? 0, "an explicit refresh reloads")
        tabs.select(.fleet)
        let settled = models.capacityModel?.loads
        tabs.refreshVisibleSection()
        XCTAssertEqual(models.capacityModel?.loads, settled, "no reload while another section is showing")
    }

    // MARK: - Diagnostics

    func testDiagnosticsOpensOnHealthAndProbesOnce() async throws {
        let diagnostics = models.ensureDiagnosticsModel()
        var probes = 0
        let report = try JSONDecoder().decode(DoctorReport.self, from: Data(Self.doctorFixture.utf8))
        diagnostics.loadReport = {
            probes += 1
            return report
        }
        tabs.select(.diagnostics)
        XCTAssertEqual(tabs.diagnosticsPane, .health)
        await waitUntil("the health report rendered") { !diagnostics.rows.isEmpty }
        XCTAssertEqual(probes, 1, "opening Diagnostics probes once")

        tabs.refreshVisibleSection()
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(probes, 1, "a window refresh never starts the probe")
    }

    func testEachDiagnosticsPaneBuildsItsModel() {
        tabs.showDiagnostics(.logs)
        XCTAssertNotNil(models.logsModel)
        tabs.selectDiagnosticsPane(.containers)
        XCTAssertNotNil(models.containersModel)
        tabs.selectDiagnosticsPane(.benchmarks)
        XCTAssertNotNil(models.benchmarksModel)
        tabs.selectDiagnosticsPane(.tools)
        XCTAssertEqual(tabs.diagnosticsPane, .tools)
        XCTAssertEqual(tabs.selectedSection, .diagnostics)
    }

    func testDiagnosticsModelsAreReusedAcrossVisits() {
        let logs = models.ensureLogsModel()
        XCTAssertTrue(models.ensureLogsModel() === logs)
        let diagnostics = models.ensureDiagnosticsModel()
        XCTAssertTrue(models.ensureDiagnosticsModel() === diagnostics)
    }

    private static let doctorFixture = """
        {
          "host": {"logicalCores": 10, "memoryGB": 32, "freeDiskGB": 200, "arm64": true},
          "clt": {"state": "ok", "version": "15.0", "ok": true, "fixCommand": null, "fixHint": null},
          "tart": {"state": "healthy", "ok": true, "reason": null, "repairCommands": []},
          "container": null,
          "docker": null,
          "toolchainCache": {"root": "/tmp/kinhin-cache", "usable": true, "sharedWithRunners": true, "warning": false, "totalBytes": 1234, "ecosystems": []},
          "auth": {"forges": [], "allGood": true},
          "checks": [],
          "ready": true,
          "capacity": {"maxConcurrent": 4, "bindingConstraint": "cpu (need 4 cores per VM)", "fits": true, "jobSlots": 8}
        }
        """

    // MARK: - Sheets

    func testSponsorSheetPresentsAndDismisses() {
        XCTAssertNil(tabs.sheet)
        tabs.present(.sponsor)
        XCTAssertEqual(tabs.sheet, .sponsor)
        tabs.dismissSheet()
        XCTAssertNil(tabs.sheet)
    }

    func testSponsorSheetIsRefusedWhileSetupGatesTheWindow() {
        fleet.setupIncomplete = true
        tabs.present(.sponsor)
        XCTAssertNil(tabs.sheet, "no sheets while first-run setup gates the window")
        fleet.setupIncomplete = false
        tabs.present(.sponsor)
        XCTAssertEqual(tabs.sheet, .sponsor)
    }

    // MARK: - Sidebar

    func testEverySectionHasADistinctSidebarIconFromTheDesign() {
        XCTAssertEqual(
            MainSection.allCases.map(\.symbol),
            ["server.rack", "cpu", "person.2", "wrench.and.screwdriver", "stethoscope", "gearshape"])
        XCTAssertEqual(Set(MainSection.allCases.map(\.symbol)).count, MainSection.allCases.count)
    }

    func testSidebarCollapseTogglesAndPersistsUnderTheExistingKey() {
        XCTAssertFalse(tabs.sidebarCollapsed)
        tabs.toggleSidebar()
        XCTAssertTrue(tabs.sidebarCollapsed)
        XCTAssertTrue(models.prefs.bool(forKey: "advancedSidebarCollapsed"), "the key predates the redesign")
        XCTAssertEqual(MainTabsModel.sidebarCollapsedKey, "advancedSidebarCollapsed")

        let reopened = MainTabsModel(fleet: fleet, models: models)
        XCTAssertTrue(reopened.sidebarCollapsed, "the choice survives a relaunch")
        tabs.toggleSidebar()
        XCTAssertFalse(tabs.sidebarCollapsed)
    }

    func testSelectingASectionWhileCollapsedStillBuildsIt() {
        tabs.toggleSidebar()
        tabs.select(.toolchains)
        XCTAssertEqual(tabs.selectedSection, .toolchains)
        XCTAssertNotNil(models.toolchainsModel)
    }
}
