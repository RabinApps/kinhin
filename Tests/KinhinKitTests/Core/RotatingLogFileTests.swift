import XCTest

@testable import KinhinKit

final class RotatingLogFileTests: XCTestCase {
    private var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("kinhin-log-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: dir)
    }

    private func read(_ name: String) -> String? {
        try? String(contentsOf: dir.appendingPathComponent(name), encoding: .utf8)
    }

    private func exists(_ name: String) -> Bool {
        FileManager.default.fileExists(atPath: dir.appendingPathComponent(name).path)
    }

    func testAppendsWithoutRotatingUnderTheCap() throws {
        let log = try RotatingLogFile(url: dir.appendingPathComponent("kinhin.log"), maxBytes: 100, keep: 2)
        try log.append(Data("one\n".utf8))
        try log.append(Data("two\n".utf8))
        XCTAssertEqual(read("kinhin.log"), "one\ntwo\n")
        XCTAssertFalse(exists("kinhin.log.1"))
    }

    func testRotatesWhenTheCapIsExceeded() throws {
        let log = try RotatingLogFile(url: dir.appendingPathComponent("kinhin.log"), maxBytes: 10, keep: 2)
        try log.append(Data("aaaaaa\n".utf8))  // 7 bytes
        try log.append(Data("bbbbbb\n".utf8))  // would reach 14 > 10, rotate first
        XCTAssertEqual(read("kinhin.log.1"), "aaaaaa\n")
        XCTAssertEqual(read("kinhin.log"), "bbbbbb\n")
    }

    func testKeepsOnlyTheConfiguredNumberOfArchives() throws {
        let log = try RotatingLogFile(url: dir.appendingPathComponent("kinhin.log"), maxBytes: 5, keep: 2)
        for name in ["first", "second", "third", "fourth"] {
            try log.append(Data("\(name)\n".utf8))
        }
        XCTAssertEqual(read("kinhin.log"), "fourth\n")
        XCTAssertEqual(read("kinhin.log.1"), "third\n")
        XCTAssertEqual(read("kinhin.log.2"), "second\n")
        XCTAssertFalse(exists("kinhin.log.3"), "the oldest archive must be dropped")
    }

    func testResumesSizeFromAnExistingFile() throws {
        let path = dir.appendingPathComponent("kinhin.log")
        try Data("existing existing\n".utf8).write(to: path)  // 18 bytes
        let log = try RotatingLogFile(url: path, maxBytes: 20, keep: 1)
        try log.append(Data("new\n".utf8))  // 22 > 20
        XCTAssertEqual(read("kinhin.log.1"), "existing existing\n")
        XCTAssertEqual(read("kinhin.log"), "new\n")
    }

    func testSingleLineLargerThanTheCapIsStillWritten() throws {
        let log = try RotatingLogFile(url: dir.appendingPathComponent("kinhin.log"), maxBytes: 4, keep: 1)
        try log.append(Data("far longer than four bytes\n".utf8))
        XCTAssertEqual(read("kinhin.log"), "far longer than four bytes\n")
    }

    func testOpenFailureThrowsInsteadOfBeingSwallowed() {
        let missingDirectory = dir.appendingPathComponent("nope/kinhin.log")
        XCTAssertThrowsError(try RotatingLogFile(url: missingDirectory))
    }
}
