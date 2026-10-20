import XCTest

@testable import KinhinKit

final class FleetBackendAttachmentTests: XCTestCase {
    func testAttachmentWaitsForARestartingDaemon() async {
        let attempts = Locked(0)
        let backend = await FleetBackend.attachToDaemon(client: RPCClient(), retryCount: 3) {
            attempts.withLock {
                $0 += 1
                return $0 == 3
            }
        }

        XCTAssertNotNil(backend)
        XCTAssertEqual(attempts.withLock { $0 }, 3)
    }

    func testAttachmentFallsBackAfterItsRetriesAreExhausted() async {
        let attempts = Locked(0)
        let backend = await FleetBackend.attachToDaemon(client: RPCClient(), retryCount: 1) {
            attempts.withLock { $0 += 1 }
            return false
        }

        XCTAssertNil(backend)
        XCTAssertEqual(attempts.withLock { $0 }, 2)
    }

    func testNormalAttachmentDoesNotWaitForAnAbsentDaemon() async {
        let attempts = Locked(0)
        let backend = await FleetBackend.attachToDaemon(client: RPCClient(), retryCount: 0) {
            attempts.withLock { $0 += 1 }
            return false
        }

        XCTAssertNil(backend)
        XCTAssertEqual(attempts.withLock { $0 }, 1)
    }
}
