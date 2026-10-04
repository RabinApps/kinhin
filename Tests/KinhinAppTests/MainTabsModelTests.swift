import XCTest

@testable import KinhinKit
@testable import kinhin_app

/// Navigation rules behind the main window: tab order, the Setup tab's
/// lifetime, lazy section building, and the sheets.
@MainActor
final class MainTabsModelTests: MainWindowTestCase {

    override func setUp() async throws {
        try await super.setUp()
        models.tokenProbe = { _ in false }  // never touch the Keychain
    }

    // MARK: - Tabs

    func testStartsOnFleetWithoutBuildingAnySection() {
        XCTAssertEqual(tabs.selectedTab, .fleet)
        XCTAssertNil(models.connectModel)
        XCTAssertNil(models.capacityModel)
        XCTAssertNil(models.wizardModel)
    }

    func testSetupTabFollowsFleetControllerSetupState() {
        XCTAssertEqual(tabs.visibleTabs, [.fleet, .detail, .advanced])
        fleet.setupIncomplete = true
        XCTAssertEqual(tabs.visibleTabs, [], "no tab bar while setup gates the window")
        XCTAssertTrue(tabs.isGatedBySetup)
        tabs.setupIncomplete = false
        XCTAssertFalse(fleet.setupIncomplete, "the model writes through to the controller")
    }

    func testSelectedSetupTabReadsAsFleetOnceSetupCompletes() {
        fleet.setupIncomplete = true
        tabs.select(.setup)
        XCTAssertEqual(tabs.selectedTab, .setup)
        fleet.setupIncomplete = false  // e.g. the delegate finished bootstrapping
        XCTAssertEqual(tabs.selectedTab, .fleet, "a vanished tab can't stay selected")
    }

    func testSelectingSetupAfterOnboardingLandsOnAccounts() {
        tabs.select(.setup)
        XCTAssertEqual(tabs.selectedTab, .advanced)
        XCTAssertEqual(tabs.advancedSection, .accounts)
        XCTAssertNil(models.wizardModel)
    }

    func testShowSetupKeepsAWizardThatIsAlreadyUp() throws {
        fleet.setupIncomplete = true
        tabs.showSetup()
        let first = try XCTUnwrap(models.wizardModel)
        tabs.select(.fleet)
        tabs.select(.setup)
        XCTAssertTrue(models.wizardModel === first, "the tab bar keeps the wizard's state")
        tabs.showSetup()
        XCTAssertTrue(models.wizardModel === first, "the menu's Setup… must not discard typed input")
    }

    func testWizardFinishHandsOffToTheAppAndRemovesTheTab() throws {
        fleet.setupIncomplete = true
        var finished = 0
        tabs.onSetupFinished = { finished += 1 }
        tabs.showSetup()
        try XCTUnwrap(models.wizardModel).onFinished?()

        XCTAssertEqual(finished, 1)
        XCTAssertEqual(tabs.selectedTab, .fleet)
        XCTAssertFalse(fleet.setupIncomplete)
        XCTAssertNil(models.wizardModel)
    }

    // MARK: - Setup gating

    func testGatedWindowIgnoresTabSwitchesAndAlwaysShowsTheWizard() {
        fleet.setupIncomplete = true
        tabs.select(.fleet)
        XCTAssertEqual(tabs.selectedTab, .setup)
        XCTAssertNotNil(models.wizardModel)
        tabs.userSelected(.advanced)
        XCTAssertEqual(tabs.selectedTab, .setup)
        tabs.showAdvanced(.routing)
        XCTAssertEqual(tabs.selectedTab, .setup)
        XCTAssertNil(models.runtimesModel, "no Advanced section is built behind the wizard")
        XCTAssertEqual(tabs.visibleTabs, [])
    }

    func testGatedWindowIgnoresLogsAndDiagnosticsRequests() {
        fleet.setupIncomplete = true
        tabs.present(.logs)
        tabs.present(.diagnostics)
        models.fleetModel.onShowLogs()
        models.fleetModel.onShowDiagnostics()
        XCTAssertNil(tabs.sheet)
        XCTAssertNil(models.logsModel)
        XCTAssertNil(models.diagnosticsModel)
    }

    func testTabBarAppearsAndFleetOpensWhenTheWizardFinishes() throws {
        fleet.setupIncomplete = true
        tabs.showSetup()
        XCTAssertTrue(tabs.isGatedBySetup)
        try XCTUnwrap(models.wizardModel).onFinished?()
        XCTAssertFalse(tabs.isGatedBySetup)
        XCTAssertEqual(tabs.visibleTabs, [.fleet, .detail, .advanced])
        XCTAssertEqual(tabs.selectedTab, .fleet)
        tabs.select(.advanced)
        XCTAssertEqual(tabs.selectedTab, .advanced, "navigation works again")
    }

    func testReopeningSetupAfterOnboardingStaysInAdvancedWithTheTabBar() {
        tabs.showSetup()
        XCTAssertFalse(tabs.isGatedBySetup)
        XCTAssertEqual(tabs.selectedTab, .advanced)
        XCTAssertEqual(tabs.visibleTabs, [.fleet, .detail, .advanced])
    }

    func testApplySetupInProgressOnlyActsDuringOnboarding() {
        tabs.applySetupInProgress()
        XCTAssertEqual(tabs.selectedTab, .fleet)
        fleet.setupIncomplete = true
        tabs.applySetupInProgress()
        XCTAssertEqual(tabs.selectedTab, .setup)
    }

    func testFleetTabButtonForSetupOpensTheWizard() {
        fleet.setupIncomplete = true
        models.fleetModel.onNeedsSetup()
        XCTAssertEqual(tabs.selectedTab, .setup)
    }

    func testOpenConfigButtonIsWiredThroughTheWindowController() {
        tabs.openConfig()
        XCTAssertEqual(delegate.openConfigCalls, 1, "the Setup footer button should reach the window delegate")
    }

    // MARK: - Advanced sections

    func testFirstVisitBuildsTheCurrentSectionAndLaterSwitchesDontReload() {
        tabs.select(.advanced)
        XCTAssertNotNil(models.connectModel, "Accounts is the first section")
        tabs.showAdvanced(.capacity)
        XCTAssertEqual(models.capacityModel?.loads, 1, "built and loaded once")
        tabs.select(.fleet)
        tabs.select(.advanced)
        tabs.showAdvanced(.capacity)
        XCTAssertEqual(models.capacityModel?.loads, 1, "Capacity is never reloaded: unapplied edits would be lost")
    }

    func testDataBackedSectionsReloadEveryTimeTheyAreShown() {
        tabs.showAdvanced(.routing)
        let afterFirst = models.runtimesModel?.loads ?? 0
        tabs.showAdvanced(.containers)
        tabs.showAdvanced(.routing)
        XCTAssertGreaterThan(models.runtimesModel?.loads ?? 0, afterFirst)
    }

    func testRefreshVisibleTabNeverProbesOutsideAdvanced() {
        tabs.refreshVisibleTab()
        XCTAssertNil(models.connectModel, "the Fleet tab refresh builds nothing")
        tabs.showAdvanced(.capacity)
        let loads = models.capacityModel?.loads
        tabs.refreshVisibleTab()
        XCTAssertGreaterThan(models.capacityModel?.loads ?? 0, loads ?? 0, "an explicit refresh reloads")
        tabs.select(.fleet)
        let settled = models.capacityModel?.loads
        tabs.refreshVisibleTab()
        XCTAssertEqual(models.capacityModel?.loads, settled, "no reload while another tab is showing")
    }

    // MARK: - Sheets

    func testLogsAndDiagnosticsSheetsPresentAndDismiss() throws {
        let diagnostics = models.ensureDiagnosticsModel()
        // A fixture builder: never run the live doctor probe.
        let fixture = DoctorReportBuilder(
            host: HostResources(logicalCores: 8, memoryGB: 16, freeDiskGB: 100, arm64: true),
            clt: .ok(version: "26.0"), tartHealth: .healthy, tartList: [], config: .missing,
            authLoad: { _ in nil }, accountLoad: { _, _ in nil })
        diagnostics.loadReport = { await fixture.build() }
        tabs.present(.logs)
        XCTAssertEqual(tabs.sheet, .logs)
        XCTAssertNotNil(models.logsModel)
        tabs.dismissSheet()
        XCTAssertNil(tabs.sheet)

        tabs.present(.diagnostics)
        XCTAssertEqual(tabs.sheet, .diagnostics)
        tabs.dismissSheet()
        XCTAssertNil(tabs.sheet)
    }

    func testSheetModelsAreReusedAcrossPresentations() {
        let logs = models.ensureLogsModel()
        XCTAssertTrue(models.ensureLogsModel() === logs)
        let diagnostics = models.ensureDiagnosticsModel()
        XCTAssertTrue(models.ensureDiagnosticsModel() === diagnostics)
    }

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
}
