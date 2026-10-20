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

    func testMissingBinaryPathsCannotTriggerARestart() {
        let current = URL(fileURLWithPath: "/Applications/kinhin.app/Contents/Resources/bin/kinhin")
        XCTAssertFalse(Daemon.targetsCurrentBinary(nil, currentBinaryURL: current))
        XCTAssertFalse(Daemon.targetsCurrentBinary("", currentBinaryURL: current))
        XCTAssertFalse(Daemon.targetsCurrentBinary(current.path, currentBinaryURL: nil))
    }

    func testAnAgentPointingAtAnotherInstallationCannotRestart() {
        let current = URL(fileURLWithPath: "/Applications/kinhin.app/Contents/Resources/bin/kinhin")
        XCTAssertFalse(Daemon.targetsCurrentBinary("/opt/homebrew/bin/kinhin", currentBinaryURL: current))
    }

    func testCurrentAppBinaryAndSymlinksToItCanRestart() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("kinhin-restart-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let binary = root.appendingPathComponent("kinhin.app/Contents/Resources/bin/kinhin")
        try FileManager.default.createDirectory(
            at: binary.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data().write(to: binary)
        let link = root.appendingPathComponent("kinhin")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: binary)

        XCTAssertTrue(Daemon.targetsCurrentBinary(binary.path, currentBinaryURL: binary))
        XCTAssertTrue(Daemon.targetsCurrentBinary(link.path, currentBinaryURL: binary))
    }
}
