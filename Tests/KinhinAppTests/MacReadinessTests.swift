import XCTest

@testable import kinhin_app

final class MacReadinessTests: XCTestCase {
    func testNothingConfiguredIsNotReady() {
        let r = MacReadiness()
        XCTAssertFalse(r.isReady)
        XCTAssertEqual(r.runsOnDescription, "nothing yet")
    }

    func testTartAloneIsReady() {
        let r = MacReadiness(tartReady: true)
        XCTAssertTrue(r.isReady)
        XCTAssertEqual(r.runsOnDescription, "macOS jobs (tart)")
    }

    func testAnEnabledRuntimeCountsOnlyWhenInstalled() {
        var r = MacReadiness(dockerEnabled: true)
        XCTAssertFalse(r.isReady, "enabled but not installed does not run jobs")
        r.dockerInstalled = true
        XCTAssertTrue(r.isReady, "a Linux-only Mac is a valid setup")
        XCTAssertEqual(r.activeLinuxRuntimes, ["Docker"])
        XCTAssertEqual(r.runsOnDescription, "Linux jobs only (Docker) — macOS jobs need tart, which isn't set up")
    }

    func testTartPlusLinuxRuntimesNamesBoth() {
        let r = MacReadiness(
            tartReady: true, containerEnabled: true, containerInstalled: true, dockerEnabled: true,
            dockerInstalled: true)
        XCTAssertEqual(r.runsOnDescription, "macOS jobs (tart) and Linux jobs (Apple container, Docker)")
    }
}
