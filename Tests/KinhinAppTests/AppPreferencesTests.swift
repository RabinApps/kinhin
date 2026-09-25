import XCTest

@testable import kinhin_app

final class AppPreferencesTests: XCTestCase {
    private var suite: UserDefaults!
    private var suiteName: String!

    override func setUp() {
        super.setUp()
        suiteName = "kinhin-tests.prefs-\(UUID().uuidString)"
        suite = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() {
        suite.removePersistentDomain(forName: suiteName)
        suite = nil
        suiteName = nil
        super.tearDown()
    }

    // MARK: launch mode

    func testDefaultLaunchModeIsMainWindowAndMenuBar() {
        XCTAssertEqual(
            AppPreferences.launchMode(in: suite), .mainWindowAndMenuBar,
            "kinhin presents as a normal app until the user opts into a tray-only setup")
        XCTAssertNil(
            suite.string(forKey: AppPreferences.launchModeKey),
            "nothing is written until the user changes the setting")
    }

    func testLaunchModeRoundTripsThroughScratchDefaults() {
        for mode in LaunchMode.allCases {
            AppPreferences.setLaunchMode(mode, in: suite)
            XCTAssertEqual(AppPreferences.launchMode(in: suite), mode)
        }
    }

    func testUnknownStoredValueFallsBackToDefault() {
        suite.set("leaf-and-branches", forKey: AppPreferences.launchModeKey)
        XCTAssertEqual(AppPreferences.launchMode(in: suite), .mainWindowAndMenuBar)
    }

    func testModeSurfaces() {
        XCTAssertEqual(LaunchMode.mainWindowAndMenuBar.showMainWindowAtLaunch, true)
        XCTAssertEqual(LaunchMode.mainWindowAndMenuBar.showsStatusItem, true)

        XCTAssertEqual(LaunchMode.menuBarOnly.showMainWindowAtLaunch, false)
        XCTAssertEqual(LaunchMode.menuBarOnly.showsStatusItem, true)

        XCTAssertEqual(LaunchMode.mainWindowOnly.showMainWindowAtLaunch, true)
        XCTAssertEqual(LaunchMode.mainWindowOnly.showsStatusItem, false)
    }

    func testAllModesHaveDistinctLabels() {
        let labels = LaunchMode.allCases.map(\.label)
        XCTAssertEqual(Set(labels).count, LaunchMode.allCases.count)
    }

    // MARK: launch at login

    func testLaunchAtLoginRoundTripsAndDefaultsToOff() {
        XCTAssertFalse(AppPreferences.launchAtLogin(in: suite))
        AppPreferences.setLaunchAtLogin(true, in: suite)
        XCTAssertTrue(AppPreferences.launchAtLogin(in: suite))
        AppPreferences.setLaunchAtLogin(false, in: suite)
        XCTAssertFalse(AppPreferences.launchAtLogin(in: suite))
    }
}
