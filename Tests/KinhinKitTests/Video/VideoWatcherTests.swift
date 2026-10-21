import XCTest

@testable import KinhinKit

/// Writes a file under `directory` (creating its folders), optionally setting its modification time. At file scope, so a task can
/// call it without capturing the test case or its type.
private func writeTestFile(in directory: URL, _ path: String, _ text: String = "x", at date: Date? = nil) throws {
    let url = directory.appendingPathComponent(path)
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try text.write(to: url, atomically: true, encoding: .utf8)
    if let date { try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: url.path) }
}

final class VideoWatcherTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("watch-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func write(_ path: String, _ text: String = "x", at date: Date? = nil) throws {
        try writeTestFile(in: directory, path, text, at: date)
    }

    func testASnapshotListsTheVideosFilesButNotWhatABuildWrites() throws {
        try write("launch.yml")
        try write("adapters/acme/adapter.yml")
        try write("out/launch/launch.mp4")
        try write(".cache/voice/a.m4a")
        try write(".DS_Store")
        XCTAssertEqual(
            Set(VideoWatcher.snapshot(of: directory).keys), ["launch.yml", "adapters/acme/adapter.yml"])
    }

    func testAMissingFolderIsAnEmptySnapshot() {
        XCTAssertTrue(VideoWatcher.snapshot(of: directory.appendingPathComponent("nope")).isEmpty)
    }

    func testChangesNameWhatWasAddedRemovedOrModified() {
        let old = Date(timeIntervalSince1970: 100)
        let new = Date(timeIntervalSince1970: 200)
        let before = ["a.yml": old, "b.yml": old, "c.yml": old]
        let after = ["a.yml": old, "b.yml": new, "d.yml": new]
        XCTAssertEqual(VideoWatcher.changes(from: before, to: after), ["b.yml", "c.yml", "d.yml"])
        XCTAssertEqual(VideoWatcher.changes(from: before, to: before), [])
    }

    func testWaitForChangeReturnsOnceTheFilesSettle() async throws {
        try write("launch.yml", at: Date(timeIntervalSince1970: 100))
        let since = VideoWatcher.snapshot(of: directory)
        let folder: URL = directory
        let writer = Task {
            try await Task.sleep(for: .milliseconds(80))
            try writeTestFile(in: folder, "launch.yml", "changed", at: Date())
            try writeTestFile(in: folder, "adapters/acme/adapter.yml")
        }
        let result = try await VideoWatcher.waitForChange(
            in: folder, since: since, poll: .milliseconds(20), settle: .milliseconds(100))
        try await writer.value
        XCTAssertEqual(result.changed, ["adapters/acme/adapter.yml", "launch.yml"])
        XCTAssertEqual(result.snapshot, VideoWatcher.snapshot(of: directory))
    }

    func testWaitForChangeStopsWhenCancelled() async throws {
        let folder: URL = directory
        let since = VideoWatcher.snapshot(of: folder)
        let waiting = Task {
            try await VideoWatcher.waitForChange(in: folder, since: since, poll: .milliseconds(20))
        }
        try await Task.sleep(for: .milliseconds(60))
        waiting.cancel()
        do {
            _ = try await waiting.value
            XCTFail("a cancelled wait should throw")
        } catch is CancellationError {
        }
    }
}
