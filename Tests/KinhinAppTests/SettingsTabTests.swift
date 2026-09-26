import AppKit
import SwiftUI
import XCTest

@testable import KinhinKit
@testable import kinhin_app

/// The Settings tab: launch mode, login and auto-start preferences.
@MainActor
final class SettingsTabTests: MainWindowTestCase {
    // MARK: - Settings tab

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
}
