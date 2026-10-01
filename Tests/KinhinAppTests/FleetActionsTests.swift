import XCTest

@testable import KinhinKit
@testable import kinhin_app

/// Daemon-mode fleet actions must throw when the daemon fails: the menu
/// wrappers alert on the error, and an App Intent reports it in Shortcuts
/// instead of claiming success.
@MainActor
final class FleetActionsTests: XCTestCase {
    private func delegateWithDeadDaemon() -> AppDelegate {
        let delegate = AppDelegate()
        let socket = FileManager.default.temporaryDirectory.appendingPathComponent("kinhin-no-daemon-\(UUID()).sock")
        delegate.fleet.backend = .daemon(RPCClient(socketURL: socket))
        return delegate
    }

    func testStartThrowsWhenTheDaemonIsUnreachable() async {
        let delegate = delegateWithDeadDaemon()
        do {
            try await delegate.fleet.perform(.start)
            XCTFail("an unreachable daemon must fail the start")
        } catch {
            XCTAssertTrue(error is RPCError, "\(error)")
        }
        XCTAssertNil(delegate.fleet.pendingFleetAction, "the pending state clears even on failure")
    }

    func testDeleteThrowsWhenTheDaemonIsUnreachable() async {
        let delegate = delegateWithDeadDaemon()
        do {
            try await delegate.fleet.deleteVM(id: "kinhin-1")
            XCTFail("an unreachable daemon must fail the delete")
        } catch {
            XCTAssertTrue(error is RPCError, "\(error)")
        }
    }
}
