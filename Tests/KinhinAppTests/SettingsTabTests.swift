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
        tabs.showAdvanced(.app)
        // Init read the stored (default) mode; the delegate must not have
        // been called back — no re-persist loop at construction time.
        XCTAssertEqual(models.appModel.launchMode, .mainWindowAndMenuBar)
        XCTAssertTrue(models.appModel.launchMode.subtitle.contains("menu bar"))
        XCTAssertTrue(delegate.changedModes.isEmpty)
    }

    func testChoosingAModeUpdatesTheCardAndNotifiesTheDelegate() {
        tabs.showAdvanced(.app)
        models.appModel.setLaunchMode(.menuBarOnly)
        XCTAssertEqual(delegate.changedModes, [.menuBarOnly])
        XCTAssertEqual(models.appModel.launchMode, .menuBarOnly)

        models.appModel.setLaunchMode(.mainWindowOnly)
        XCTAssertEqual(delegate.changedModes, [.menuBarOnly, .mainWindowOnly])
        XCTAssertEqual(models.appModel.launchMode, .mainWindowOnly)
        XCTAssertTrue(
            models.appModel.launchMode.subtitle.contains("no menu bar item"), "subtitle tracks the picked mode")
    }

    func testChosenModePersistsToTheInjectedDefaults() {
        models.appModel.setLaunchMode(.mainWindowOnly)
        XCTAssertEqual(
            AppPreferences.launchMode(in: suite), .mainWindowOnly,
            "the choice must survive a relaunch via the injected suite")
        models.appModel.setLaunchMode(.menuBarOnly)
        XCTAssertEqual(AppPreferences.launchMode(in: suite), .menuBarOnly)
    }

    func testLoginCheckboxPersistsAndNotifies() {
        tabs.showAdvanced(.app)
        models.appModel.setLaunchAtLogin(true)
        XCTAssertEqual(delegate.loginToggles, [true])
        XCTAssertTrue(AppPreferences.launchAtLogin(in: suite))

        models.appModel.setLaunchAtLogin(false)
        XCTAssertEqual(delegate.loginToggles, [true, false])
        XCTAssertFalse(AppPreferences.launchAtLogin(in: suite))
    }

    func testAutoStartCheckboxPersists() {
        tabs.showAdvanced(.app)
        XCTAssertFalse(models.appModel.autoStartFleet)
        models.appModel.setAutoStartFleet(true)
        XCTAssertTrue(AppPreferences.autoStartFleet(in: suite))
        models.appModel.setAutoStartFleet(false)
        XCTAssertFalse(AppPreferences.autoStartFleet(in: suite))
    }
}
