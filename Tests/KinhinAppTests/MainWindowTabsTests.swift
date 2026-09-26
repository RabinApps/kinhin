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

    // MARK: - Tab structure

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
}
