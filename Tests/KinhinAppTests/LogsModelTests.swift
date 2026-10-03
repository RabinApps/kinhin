import XCTest

@testable import KinhinKit
@testable import kinhin_app

/// The log viewer appends new lines instead of rebuilding the whole text.
@MainActor
final class LogsModelTests: XCTestCase {
    private var nextSeq: UInt64 = 1

    private func entry(_ message: String, level: String = "info") -> Log.Entry {
        defer { nextSeq += 1 }
        return Log.Entry(timestamp: Date(), level: level, component: "t", message: message, seq: nextSeq)
    }

    func testNewEntriesAreAppendedWithoutRebuilding() {
        let model = LogsModel()
        let a = entry("first")
        let b = entry("second")
        model.refresh(from: [a, b])
        let rebuilds = model.rebuildRevision
        let revision = model.revision
        XCTAssertTrue(model.text.string.contains("first"))

        let c = entry("third")
        model.refresh(from: [a, b, c])
        XCTAssertEqual(model.rebuildRevision, rebuilds, "appended, not rebuilt")
        XCTAssertEqual(model.revision, revision + 1)
        XCTAssertTrue(model.appended.string.contains("third"))
        XCTAssertFalse(model.appended.string.contains("first"), "only the new line is the delta")
        XCTAssertTrue(model.text.string.hasSuffix(c.formatted + "\n"))
        XCTAssertEqual(model.entries.count, 3)
    }

    func testNothingNewChangesNothing() {
        let model = LogsModel()
        let a = entry("only")
        model.refresh(from: [a])
        let revision = model.revision
        model.refresh(from: [a])
        XCTAssertEqual(model.revision, revision)
    }

    func testFilteredOutNewLinesDoNotTouchTheText() {
        let model = LogsModel()
        let a = entry("keep me")
        model.refresh(from: [a])
        model.query = "keep"
        let revision = model.revision
        let b = entry("something else")
        model.refresh(from: [a, b])
        XCTAssertEqual(model.revision, revision, "the new line does not match the search")
        XCTAssertEqual(model.entries.count, 2)
        let c = entry("keep this too")
        model.refresh(from: [a, b, c])
        XCTAssertTrue(model.appended.string.contains("keep this too"))
    }

    func testChangingTheFilterRebuildsFromCachedLines() {
        let model = LogsModel()
        let info = entry("info line")
        let warn = entry("warn line", level: "warn")
        model.refresh(from: [info, warn])
        let rebuilds = model.rebuildRevision
        model.minLevel = .warn
        XCTAssertEqual(model.rebuildRevision, rebuilds + 1)
        XCTAssertFalse(model.text.string.contains("info line"))
        XCTAssertTrue(model.text.string.contains("warn line"))
    }

    func testPlaceholderGivesWayToTheFirstLines() {
        let model = LogsModel()
        model.refresh(from: [])
        XCTAssertEqual(model.text.string, "No log lines yet.")
        let a = entry("hello")
        model.refresh(from: [a])
        XCTAssertEqual(model.text.string, a.formatted + "\n")
    }

    func testTheBufferTrimsInChunksNotOnEveryRefresh() {
        let model = LogsModel()
        var all = (0..<LogsModel.capacity).map { entry("line \($0)") }
        model.refresh(from: all)
        let rebuilds = model.rebuildRevision
        // A few more lines: within the slack, still appended.
        let extra = entry("extra")
        all.append(extra)
        model.refresh(from: Array(all.suffix(LogsModel.capacity)))
        XCTAssertEqual(model.rebuildRevision, rebuilds)
        XCTAssertEqual(model.entries.count, LogsModel.capacity + 1)
        // Past capacity + slack: trimmed back with one rebuild.
        for i in 0..<(LogsModel.slack + 5) { all.append(entry("more \(i)")) }
        model.refresh(from: Array(all.suffix(LogsModel.capacity)))
        XCTAssertEqual(model.entries.count, LogsModel.capacity)
        XCTAssertEqual(model.rebuildRevision, rebuilds + 1)
        XCTAssertTrue(model.text.string.hasSuffix(all.last!.formatted + "\n"))
    }
}
