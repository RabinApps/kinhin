import KinhinKit
import Synchronization
import XCTest

@testable import kinhin

/// The Ctrl-C bridge: the first signal cancels the running command's task,
/// the second hard-exits. `fire()` is driven directly — no real signal.
final class InterruptBridgeTests: XCTestCase {
    func testFirstFireCancelsAndSecondFireExits() {
        let cancels = Locked(0)
        let exits = Locked(0)
        let bridge = InterruptBridge(
            cancel: { cancels.withLock { $0 += 1 } },
            exitNow: { exits.withLock { $0 += 1 } })

        bridge.fire()
        bridge.fire()

        XCTAssertEqual(cancels.withLock { $0 }, 1, "the first Ctrl-C cancels cooperatively")
        XCTAssertEqual(exits.withLock { $0 }, 1, "the second Ctrl-C is the escape hatch")
    }

    func testRepeatedCancelsDoNotExit() {
        let cancels = Locked(0)
        let exits = Locked(0)
        let bridge = InterruptBridge(
            cancel: { cancels.withLock { $0 += 1 } },
            exitNow: { exits.withLock { $0 += 1 } })

        bridge.fire()
        bridge.fire()
        bridge.fire()

        XCTAssertEqual(cancels.withLock { $0 }, 1)
        XCTAssertEqual(exits.withLock { $0 }, 2, "every signal after the first exits")
    }

    func testBridgesAreIndependent() {
        let cancels = Locked(0)
        let first = InterruptBridge(cancel: { cancels.withLock { $0 += 1 } }, exitNow: {})
        let second = InterruptBridge(cancel: { cancels.withLock { $0 += 1 } }, exitNow: {})

        first.fire()
        second.fire()

        XCTAssertEqual(cancels.withLock { $0 }, 2, "each command run gets a fresh bridge")
    }
}
