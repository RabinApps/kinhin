import AppKit
import SwiftUI
import XCTest

@testable import KinhinKit
@testable import kinhin_app

/// Window-level decisions and section structure: which sections exist when,
/// section switching, and the setup wizard's steps.
@MainActor
final class MainWindowTabsTests: MainWindowTestCase {
    // MARK: - Pure decisions

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

    func testClosingTheWindowTellsTheDelegateEvenWithASheetUp() {
        tabs.present(.sponsor)
        window.windowWillClose(Notification(name: NSWindow.willCloseNotification))
        XCTAssertEqual(delegate.closeCalls, 1, "the app re-evaluates its activation policy and quit-on-close")
    }

    // MARK: - Section structure

    func testSectionsInSidebarOrder() {
        XCTAssertEqual(MainSection.allCases, [.fleet, .runtimes, .accounts, .toolchains, .diagnostics, .settings])
        XCTAssertEqual(
            MainSection.allCases.map(\.label),
            ["Fleet", "Runtimes", "Accounts", "Toolchains", "Diagnostics", "Settings"])
        XCTAssertEqual(
            DiagnosticsPane.allCases.map(\.label), ["Health", "Logs", "Benchmarks", "Containers", "Tools"])
    }

    func testSidebarIsHiddenWhileSetupIsUnfinished() {
        XCTAssertEqual(tabs.visibleSections.count, 6, "a configured app shows every section")

        tabs.setupIncomplete = true
        XCTAssertEqual(tabs.visibleSections, [], "only the wizard is shown")
        XCTAssertTrue(tabs.isGatedBySetup)

        tabs.setupIncomplete = false
        XCTAssertEqual(tabs.visibleSections.count, 6, "finishing setup reveals the sidebar")
    }

    func testWindowStartsOnFleet() {
        XCTAssertEqual(tabs.selectedSection, .fleet)
    }

    func testSelectingASectionSwapsThePage() {
        tabs.select(.settings)
        XCTAssertEqual(tabs.selectedSection, .settings)
        tabs.select(.fleet)
        XCTAssertEqual(tabs.selectedSection, .fleet)
    }

    func testSidebarSelectionSwitchesSections() {
        tabs.userSelected(.toolchains)
        XCTAssertEqual(tabs.selectedSection, .toolchains)
    }

    func testWizardOwnsTheWindowDuringOnboardingAndHandsOffWhenDone() {
        tabs.setupIncomplete = true
        tabs.showSetup()
        XCTAssertTrue(tabs.isGatedBySetup)
        XCTAssertNotNil(models.wizardModel, "first run shows the guided wizard")

        // Finishing removes the gate and hands the window to Fleet.
        finishSetupForTesting()
        XCTAssertEqual(tabs.selectedSection, .fleet)
        XCTAssertEqual(tabs.visibleSections.count, 6)
        XCTAssertNil(models.wizardModel)
        XCTAssertEqual(delegate.setupFinishedCalls, 1, "the delegate re-bootstraps the engine")
    }

    func testSetupCannotBeLeftEarlyFromTheLastStep() {
        let wizard = showWizard()
        wizard.skip()  // connect → mac
        wizard.skip()  // mac → review
        XCTAssertFalse(wizard.canSkip, "there is no Finish later")
        wizard.skip()
        XCTAssertEqual(wizard.step, .review)
        XCTAssertTrue(tabs.isGatedBySetup)
        XCTAssertEqual(tabs.visibleSections, [])
    }

    func testSetupIncompleteOpensTheWizardWhenTheWindowOpens() {
        tabs.setupIncomplete = true
        tabs.applySetupInProgress()
        XCTAssertTrue(tabs.isGatedBySetup)
        XCTAssertNotNil(models.wizardModel)
    }

    func testAfterSetupAccountsLiveInTheAccountsSection() {
        models.tokenProbe = { _ in false }
        tabs.setupIncomplete = false
        tabs.showSetup()  // menu "Setup…" after onboarding lands here
        XCTAssertEqual(tabs.selectedSection, .accounts)
        XCTAssertNil(models.wizardModel)
        XCTAssertNotNil(models.connectModel)
        XCTAssertNil(models.macToolsModel, "This Mac lives in Runtimes, not Accounts")
    }

    func testWizardWalksThreeSteps() {
        let wizard = showWizard()
        XCTAssertEqual(wizard.step, .connect, "the wizard opens on connecting an account")

        wizard.skip()  // connect → mac
        XCTAssertEqual(wizard.step, .mac)
        wizard.skip()  // mac → review
        XCTAssertEqual(wizard.step, .review)
        XCTAssertEqual(WizardModel.Step.allCases, [.connect, .mac, .review])
    }

    func testWizardCannotStartUntilConnectedAndReady() {
        let wizard = showWizard()
        wizard.skip()  // connect → mac
        wizard.skip()  // mac → review
        XCTAssertEqual(wizard.step, .review)
        // Nothing connected in a hermetic test: pressing Start must not
        // finish (it would bounce the app straight back into setup).
        XCTAssertFalse(wizard.canContinue)
        wizard.next()
        XCTAssertEqual(delegate.setupFinishedCalls, 0)
        XCTAssertEqual(wizard.currentBlockers.count, 2, "both blockers are said, for the view to show")
        XCTAssertTrue(
            wizard.summaryText.contains("Still needed"),
            "the summary says what is missing: \(wizard.summaryText)")
    }

    func testWizardBackNavigation() {
        let wizard = showWizard()
        wizard.skip()
        wizard.skip()  // mac → review
        wizard.back()
        XCTAssertEqual(wizard.step, .mac)
        wizard.back()
        XCTAssertEqual(wizard.step, .connect)
    }

    func testRuntimesHostsTheLoadedCapacityForm() {
        tabs.select(.runtimes)
        XCTAssertEqual(tabs.selectedSection, .runtimes)
        XCTAssertNotNil(models.capacityModel, "Runtimes embeds the capacity form model")
    }

    /// Accounts and Runtimes are separate: Accounts keeps the Connect form alone; Runtimes hosts This Mac above the
    /// capacity cards and the routing.
    func testMacAndVmSettingsShareTheRuntimesSection() {
        tabs.select(.accounts)
        XCTAssertNotNil(models.connectModel)
        XCTAssertNil(models.macToolsModel, "Accounts no longer builds This Mac")

        tabs.select(.runtimes)
        XCTAssertNotNil(models.macToolsModel, "Runtimes builds This Mac")
        XCTAssertNotNil(models.capacityModel, "and its own capacity form")
        XCTAssertNotNil(models.runtimesModel, "and the routing model")
    }

    func testSelectingTheRuntimesSectionLoadsIt() {
        // Regression: the form rendered blank because nothing ever loaded the
        // config into it — reloads deliberately skip the capacity form (to
        // protect unapplied edits), so the fresh model must fetch its own
        // snapshot when its section is built.
        let fresh = MainTabsWindowController(
            defaults: UserDefaults(suiteName: "kinhin-capacity-\(UUID().uuidString)")!, fleet: FleetController(),
            updates: UpdateController())
        fresh.tabs.select(.runtimes)
        XCTAssertGreaterThanOrEqual(
            fresh.models.capacityModel?.loads ?? 0, 1, "the section must load its config on first open")
    }

    /// Every section must have its model built and loaded on first open. A section hosted on an @Observable model
    /// renders an empty form when the model never loaded, so "the section exists" proves nothing — the data-backed
    /// ones must have fetched their config.
    func testEverySectionBuildsItsModelOnFirstOpen() {
        // A fresh window per section, because sections build their models
        // lazily on first selection — the real-user path.
        for section in MainSection.allCases {
            let fresh = MainTabsWindowController(
                defaults: UserDefaults(suiteName: "kinhin-sections-\(UUID().uuidString)")!, fleet: FleetController(),
                updates: UpdateController())
            fresh.models.tokenProbe = { _ in false }
            let fixture = DoctorReportBuilder(
                host: HostResources(logicalCores: 8, memoryGB: 16, freeDiskGB: 100, arm64: true),
                clt: .ok(version: "26.0"), tartHealth: .healthy, tartList: [], config: .missing,
                authLoad: { _ in nil }, accountLoad: { _, _ in nil })
            fresh.models.ensureDiagnosticsModel().loadReport = { await fixture.build() }
            fresh.tabs.select(section)
            let models = fresh.models
            switch section {
            case .fleet: XCTAssertNil(models.capacityModel, "Fleet builds nothing")
            case .runtimes:
                XCTAssertGreaterThanOrEqual(models.capacityModel?.loads ?? 0, 1)
                XCTAssertNotNil(models.macToolsModel, "Runtimes embeds the This Mac form beside the capacity cards")
                XCTAssertGreaterThanOrEqual(
                    models.runtimesModel?.loads ?? 0, 1, "Runtimes hosts the Budget card and Routing")
            case .accounts: XCTAssertNotNil(models.connectModel, "Accounts builds Connect")
            case .toolchains: XCTAssertNotNil(models.toolchainsModel)
            case .diagnostics: XCTAssertNotNil(models.diagnosticsModel)
            case .settings: XCTAssertEqual(models.appModel.launchMode, .mainWindowAndMenuBar)
            }
            XCTAssertEqual(fresh.tabs.selectedSection, section)
        }
    }
}
