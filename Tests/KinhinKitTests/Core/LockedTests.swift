import XCTest

@testable import KinhinKit

/// `Locked` is the Sendable stand-in for a local `Mutex` that two tasks share.
final class LockedTests: XCTestCase {
    func testReadsWritesAndReturnsUnderTheLock() {
        let counter = Locked(0)
        XCTAssertEqual(counter.withLock { $0 }, 0)
        counter.withLock { $0 += 5 }
        let previous = counter.withLock { value -> Int in
            defer { value = 100 }
            return value
        }
        XCTAssertEqual(previous, 5)
        XCTAssertEqual(counter.withLock { $0 }, 100)
    }

    func testManyTasksUpdateItWithoutLosingAnIncrement() async {
        let counter = Locked(0)
        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<200 {
                group.addTask { for _ in 0..<50 { counter.withLock { $0 += 1 } } }
            }
        }
        XCTAssertEqual(counter.withLock { $0 }, 10_000)
    }

    func testSharedByATaskAndTheCodeAfterIt() async {
        let finished = Locked(false)
        let task = Task { finished.withLock { $0 = true } }
        await task.value
        XCTAssertTrue(finished.withLock { $0 })
    }

    func testCanHoldAnOptionalAndThrowsPropagate() {
        struct Boom: Error {}
        let slot = Locked<Int?>(7)
        XCTAssertEqual(
            slot.withLock { value -> Int? in
                defer { value = nil }; return value
            }, 7)
        XCTAssertNil(slot.withLock { $0 })
        XCTAssertThrowsError(try slot.withLock { _ -> Int in throw Boom() })
    }
}
