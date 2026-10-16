import XCTest

@testable import KinhinKit

/// `kinhin video record`: which window a query names. The capture itself needs Screen Recording permission and a window on
/// screen, so it is checked by hand; these tests cover the choice, which is where a wrong clip would come from.
final class WindowRecorderTests: XCTestCase {
    private let windows = [
        RecordableWindow(id: 1, app: "kinhin-app", title: "kinhin", width: 800, height: 628),
        RecordableWindow(id: 2, app: "kinhin-app", title: "Diagnostics", width: 400, height: 300),
        RecordableWindow(id: 3, app: "Safari", title: "kinhin.dev", width: 1200, height: 900),
        RecordableWindow(id: 4, app: "Apple Notes", title: "Shopping", width: 500, height: 500),
    ]

    func testExactAppNameWins() throws {
        let found = try WindowRecorder.find("Safari", in: windows)
        XCTAssertEqual(found.id, 3)
    }

    func testAppNameMatchIsCaseInsensitive() throws {
        XCTAssertEqual(try WindowRecorder.find("apple notes", in: windows).id, 4)
    }

    func testPartialAppNameFindsTheApp() throws {
        XCTAssertEqual(try WindowRecorder.find("kinhin", in: windows).app, "kinhin-app")
    }

    func testSeveralWindowsOfOneAppPickTheLargest() throws {
        // Both windows belong to kinhin-app; the 800x628 main window is the one to record.
        XCTAssertEqual(try WindowRecorder.find("kinhin-app", in: windows).id, 1)
    }

    func testTitleMatchesWhenNoAppMatches() throws {
        XCTAssertEqual(try WindowRecorder.find("Shopping", in: windows).id, 4)
    }

    func testMatchingTwoAppsIsAnError() {
        // Both app names contain "Alpha", so the query fits two apps. It must refuse, not guess which one to record.
        let twoApps = [
            RecordableWindow(id: 10, app: "Alpha Tool", title: "", width: 100, height: 100),
            RecordableWindow(id: 11, app: "Alpha Notes", title: "", width: 100, height: 100),
        ]
        XCTAssertThrowsError(try WindowRecorder.find("Alpha", in: twoApps)) { error in
            XCTAssertEqual(
                error as? WindowRecorderError,
                .ambiguous(query: "Alpha", matches: ["Alpha Notes", "Alpha Tool"]))
        }
    }

    func testNoMatchListsTheWindowsOnScreen() {
        XCTAssertThrowsError(try WindowRecorder.find("Keynote", in: windows)) { error in
            guard case let .noWindow(query, available) = error as? WindowRecorderError else {
                return XCTFail("expected noWindow, got \(error)")
            }
            XCTAssertEqual(query, "Keynote")
            XCTAssertTrue(available.contains("Safari — kinhin.dev"))
            XCTAssertTrue(available.contains("Apple Notes — Shopping"))
        }
    }

    func testLabelOmitsEmptyTitles() {
        XCTAssertEqual(RecordableWindow(id: 9, app: "Finder", title: "", width: 1, height: 1).label, "Finder")
        XCTAssertEqual(windows[2].label, "Safari — kinhin.dev")
    }

    func testPermissionErrorNamesTheSettingsPane() {
        let message = WindowRecorderError.permissionMissing.errorDescription ?? ""
        XCTAssertTrue(message.contains("Screen Recording"))
        XCTAssertTrue(message.contains("System Settings"))
    }
}
