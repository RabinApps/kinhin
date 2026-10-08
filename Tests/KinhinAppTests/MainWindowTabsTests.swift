import AppKit
import SwiftUI
import XCTest

@testable import KinhinKit
@testable import kinhin_app

/// Window-level decisions and tab structure: which tabs exist when, tab
/// switching, and the setup wizard's steps.
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
        tabs.present(.logs)
        window.windowWillClose(Notification(name: NSWindow.willCloseNotification))
        XCTAssertEqual(delegate.closeCalls, 1, "the app re-evaluates its activation policy and quit-on-close")
    }

    // MARK: - Tab structure

    func testTabsAndAdvancedSectionsInDisplayOrder() {
        XCTAssertEqual(MainTab.allCases, [.fleet, .setup, .advanced])
        XCTAssertEqual(
            AdvancedSection.allCases.map(\.label),
            ["Accounts", "Capacity", "Routing", "Containers", "Toolchains", "App"])
    }

    func testTabBarIsHiddenWhileSetupIsUnfinished() {
        XCTAssertEqual(tabs.visibleTabs, [.fleet, .advanced], "a configured app has no Setup tab")
        XCTAssertEqual(tabs.visibleTabs.map(\.label), ["Fleet", "Advanced"])

        tabs.setupIncomplete = true
        XCTAssertEqual(tabs.visibleTabs, [], "only the wizard is shown")
        XCTAssertEqual(tabs.selectedTab, .setup)

        tabs.setupIncomplete = false
        XCTAssertEqual(tabs.visibleTabs, [.fleet, .advanced], "finishing setup reveals the tab bar")
    }

    func testWindowStartsOnTheFleetTab() {
        XCTAssertEqual(tabs.selectedTab, .fleet)
    }

    func testSelectingATabSwapsTheVisibleContent() {
        tabs.select(.advanced)
        XCTAssertEqual(tabs.selectedTab, .advanced)
        tabs.select(.fleet)
        XCTAssertEqual(tabs.selectedTab, .fleet)
    }

    func testTabBarSelectionSwitchesTabs() {
        tabs.userSelected(.advanced)
        XCTAssertEqual(tabs.selectedTab, .advanced)
    }

    func testWizardOwnsTheWindowDuringOnboardingAndHandsOffWhenDone() {
        tabs.setupIncomplete = true
        tabs.showSetup()
        XCTAssertEqual(tabs.selectedTab, .setup)
        XCTAssertNotNil(models.wizardModel, "first run shows the guided wizard")

        // Finishing removes the Setup tab and hands the window to Fleet.
        finishSetupForTesting()
        XCTAssertEqual(tabs.selectedTab, .fleet)
        XCTAssertEqual(tabs.visibleTabs, [.fleet, .advanced])
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
        XCTAssertEqual(tabs.selectedTab, .setup)
        XCTAssertEqual(tabs.visibleTabs, [])
    }

    func testSetupIncompleteOpensTheWizardWhenTheWindowOpens() {
        tabs.setupIncomplete = true
        tabs.applySetupInProgress()
        XCTAssertEqual(tabs.selectedTab, .setup)
        XCTAssertNotNil(models.wizardModel)
    }

    func testAfterSetupAccountsLiveInAdvanced() {
        models.tokenProbe = { _ in false }
        tabs.setupIncomplete = false
        tabs.showSetup()  // menu "Setup…" after onboarding lands here
        XCTAssertEqual(tabs.selectedTab, .advanced)
        XCTAssertEqual(tabs.advancedSection, .accounts)
        XCTAssertNil(models.wizardModel)
        XCTAssertNotNil(models.connectModel)
        XCTAssertNil(models.macToolsModel, "This Mac lives in Capacity, not Accounts")
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

    func testAdvancedCapacityHostsTheLoadedForm() {
        tabs.showAdvanced(.capacity)
        XCTAssertEqual(tabs.advancedSection, .capacity)
        XCTAssertNotNil(models.capacityModel, "Capacity embeds the form model")
    }

    /// Accounts and Capacity are separate: Accounts keeps the Connect form
    /// alone; the renamed Capacity section hosts This Mac above the cards.
    func testMacAndVmSettingsShareTheRenamedCapacitySection() {
        tabs.showAdvanced(.accounts)
        XCTAssertNotNil(models.connectModel)
        XCTAssertNil(models.macToolsModel, "Accounts no longer builds This Mac")

        tabs.showAdvanced(.capacity)
        XCTAssertNotNil(models.macToolsModel, "Capacity builds This Mac")
        XCTAssertNotNil(models.capacityModel, "and its own capacity form")
    }

    func testSelectingTheCapacitySectionLoadsIt() {
        // Regression: the form rendered blank because nothing ever loaded the
        // config into it — selectAdvancedSection deliberately skips reloads
        // for Capacity (to protect unapplied edits), so the fresh model must
        // fetch its own snapshot when its section is built.
        let fresh = MainTabsWindowController(
            defaults: UserDefaults(suiteName: "kinhin-capacity-\(UUID().uuidString)")!, fleet: FleetController(),
            updates: UpdateController())
        fresh.tabs.showAdvanced(.capacity)
        XCTAssertGreaterThanOrEqual(
            fresh.models.capacityModel?.loads ?? 0, 1, "the section must load its config on first open")
    }

    func testAdvancedSectionsEmbedTheirControllers() {
        tabs.showAdvanced(.routing)
        XCTAssertNotNil(models.runtimesModel, "Routing embeds the runtimes pane")
        tabs.showAdvanced(.app)
        XCTAssertEqual(tabs.advancedSection, .app)
    }

    /// Every Advanced section must have its model built and loaded on first
    /// open. A section hosted on an @Observable model renders an empty form
    /// when the model never loaded, so "the section exists" proves nothing —
    /// the data-backed ones must have fetched their config.
    func testEveryAdvancedSectionBuildsItsModelOnFirstOpen() {
        // A fresh window per section, because sections build their models
        // lazily on first selection — the real-user path.
        for section in AdvancedSection.allCases {
            let fresh = MainTabsWindowController(
                defaults: UserDefaults(suiteName: "kinhin-sections-\(UUID().uuidString)")!, fleet: FleetController(),
                updates: UpdateController())
            fresh.tabs.showAdvanced(section)
            let models = fresh.models
            switch section {
            case .accounts: XCTAssertNotNil(models.connectModel, "Accounts builds Connect")
            case .capacity:
                XCTAssertGreaterThanOrEqual(models.capacityModel?.loads ?? 0, 1)
                XCTAssertNotNil(
                    models.macToolsModel, "Capacity embeds the This Mac form beside the capacity cards")
                XCTAssertGreaterThanOrEqual(
                    models.runtimesModel?.loads ?? 0, 1,
                    "Capacity hosts the Budget card, so it loads the runtimes model")
            case .routing: XCTAssertGreaterThanOrEqual(models.runtimesModel?.loads ?? 0, 1)
            case .containers: XCTAssertNotNil(models.containersModel)
            case .toolchains: XCTAssertNotNil(models.toolchainsModel)
            case .app: XCTAssertEqual(models.appModel.launchMode, .mainWindowAndMenuBar)
            }
            XCTAssertEqual(fresh.tabs.selectedTab, .advanced)
            XCTAssertEqual(fresh.tabs.advancedSection, section)
        }
    }
}
