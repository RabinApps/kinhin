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
        delegate.client = RPCClient(socketURL: socket)
        return delegate
    }

    func testStartThrowsWhenTheDaemonIsUnreachable() async {
        let delegate = delegateWithDeadDaemon()
        do {
            try await delegate.performFleetAction(.start)
            XCTFail("an unreachable daemon must fail the start")
        } catch {
            XCTAssertTrue(error is RPCError, "\(error)")
        }
        XCTAssertNil(delegate.pendingFleetAction, "the pending state clears even on failure")
    }

    func testDeleteThrowsWhenTheDaemonIsUnreachable() async {
        let delegate = delegateWithDeadDaemon()
        do {
            try await delegate.performVMDelete(id: "kinhin-1")
            XCTFail("an unreachable daemon must fail the delete")
        } catch {
            XCTAssertTrue(error is RPCError, "\(error)")
        }
    }
}
