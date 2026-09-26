import XCTest

@testable import KinhinKit

final class DaemonLockTests: XCTestCase {
    private var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("kinhin-lock-\(UUID().uuidString)")
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: dir)
    }

    private var lockURL: URL { dir.appendingPathComponent("daemon.lock") }

    func testSecondAcquireWhileHeldFailsAsAlreadyRunning() throws {
        let first = try DaemonLock.acquire(at: lockURL)
        XCTAssertThrowsError(try DaemonLock.acquire(at: lockURL)) { error in
            XCTAssertEqual(error as? Daemon.DaemonError, .alreadyRunning)
        }
        withExtendedLifetime(first) {}
    }

    func testLockIsReleasedWhenTheHolderGoesAway() throws {
        var first: DaemonLock? = try DaemonLock.acquire(at: lockURL)
        XCTAssertNotNil(first)
        first = nil
        XCTAssertNoThrow(try DaemonLock.acquire(at: lockURL), "a dead daemon must not leave a stale lock")
    }

    func testDifferentLockFilesDoNotConflict() throws {
        let a = try DaemonLock.acquire(at: dir.appendingPathComponent("a.lock"))
        let b = try DaemonLock.acquire(at: dir.appendingPathComponent("b.lock"))
        withExtendedLifetime((a, b)) {}
    }

    func testRecordsThePidForDiagnostics() throws {
        let held = try DaemonLock.acquire(at: lockURL)
        let contents = try String(contentsOf: lockURL, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
        XCTAssertEqual(contents, "\(getpid())")
        withExtendedLifetime(held) {}
    }
}
