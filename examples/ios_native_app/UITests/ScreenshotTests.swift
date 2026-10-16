import XCTest

// One screenshot per screen you want in the store. Add a test method for each screen, and call snapshot() with a name
// that sorts in the order you want (for example "01-home"). See docs/mobile-screenshots.md.
// The snapshot helpers are main-actor isolated, so the test class must be too.
@MainActor
final class ScreenshotTests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        setupSnapshot(app)  // from SnapshotHelper.swift: lets fastlane set the language and device
        // The app reads this with Settings.get('KinhinLanguage'), so it knows the language without relying on AppleLanguages.
        app.launchArguments += ["-KinhinLanguage", Snapshot.deviceLanguage]
        app.launch()
    }

    func testHome() {
        snapshot("01-home")
    }
}
