import XCTest

@testable import KinhinKit

final class LogRingTests: XCTestCase {
    func testRingKeepsTheNewestItemsInOrderAfterWrapping() {
        let ring = Runaround<Int>(capacity: 5)
        for value in 1...3 { ring.append(value) }
        XCTAssertEqual(ring.snapshot(limit: 10), [1, 2, 3])
        for value in 4...12 { ring.append(value) }
        XCTAssertEqual(ring.snapshot(limit: 10), [8, 9, 10, 11, 12])
        XCTAssertEqual(ring.snapshot(limit: 2), [11, 12])
        XCTAssertEqual(ring.snapshot(limit: 0), [])
    }

    func testEntriesCarryIncreasingSequenceNumbers() {
        let first = Log.Entry.make(level: "info", component: "t", message: "a")
        let second = Log.Entry.make(level: "info", component: "t", message: "b")
        XCTAssertGreaterThan(second.seq, first.seq)
    }

    func testEntryDecodesFromAPayloadWithoutASequence() throws {
        let json = #"{"timestamp": 0, "level": "info", "component": "x", "message": "m"}"#
        let entry = try JSONDecoder().decode(Log.Entry.self, from: Data(json.utf8))
        XCTAssertEqual(entry.seq, 0)
        let roundTrip = try JSONDecoder().decode(Log.Entry.self, from: JSONEncoder().encode(first(entry)))
        XCTAssertEqual(roundTrip, first(entry))
    }

    private func first(_ entry: Log.Entry) -> Log.Entry {
        Log.Entry(timestamp: Date(timeIntervalSince1970: 1), level: "info", component: "c", message: "m", seq: 7)
    }
}
