import XCTest

@testable import KinhinKit

/// The upgrade rule: a daemon from another build (or one too old to report a version) is restarted.
final class DaemonRestartTests: XCTestCase {
    func testSameVersionNeedsNoRestart() {
        XCTAssertFalse(Daemon.needsRestart(runningVersion: "0.0.1-beta-2", current: "0.0.1-beta-2"))
    }

    func testAnotherVersionNeedsARestart() {
        XCTAssertTrue(Daemon.needsRestart(runningVersion: "0.0.1-beta-1", current: "0.0.1-beta-2"))
    }

    func testADaemonThatReportsNoVersionIsStale() {
        // Daemons that predate the version field omit it; they still run the old binary.
        XCTAssertTrue(Daemon.needsRestart(runningVersion: nil, current: "0.0.1-beta-2"))
    }
}
