import XCTest

@testable import KinhinKit

/// Paths.findExecutable: override is authoritative, then the fixed trusted directories, then PATH.
final class PathsTests: XCTestCase {
    func testOverrideWinsOverPATHWhenItExists() throws {
        let real = try XCTUnwrap(Paths.findExecutable(named: "sh"))
        XCTAssertEqual(Paths.findExecutable(named: "sh", override: real), real)
    }

    /// An explicit override pointing at nothing is a misconfiguration: it
    /// reports missing rather than probing PATH/Homebrew behind the user's
    /// back (kinhin doctor must never bless a runtime the config doesn't use).
    func testMissingOverrideIsAuthoritative() {
        // A nonexistent override reports missing — no silent PATH fallback.
        XCTAssertNil(Paths.findExecutable(named: "tart", override: "/nonexistent/kinhin-test/sh"))
        // An empty override means "not configured": normal discovery applies.
        XCTAssertNotNil(Paths.findExecutable(named: "sh", override: ""))
    }

    /// A directory a job could write to and that sits first on PATH must not shadow a system binary.
    func testTrustedDirectoriesWinOverPATH() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("kinhin-paths-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }  // test cleanup
        let fake = dir.appendingPathComponent("sh")
        try Data("#!/bin/sh\n".utf8).write(to: fake)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fake.path)

        let oldPath = ProcessInfo.processInfo.environment["PATH"]
        setenv("PATH", "\(dir.path):/usr/bin", 1)
        defer { if let oldPath { setenv("PATH", oldPath, 1) } else { unsetenv("PATH") } }

        let found = try XCTUnwrap(Paths.findExecutable(named: "sh"))
        XCTAssertTrue(Paths.trustedBinaryDirectories.contains((found as NSString).deletingLastPathComponent))
        XCTAssertNotEqual(found, fake.path)
        // A binary only present on PATH is still found afterwards.
        let only = dir.appendingPathComponent("kinhin-only-tool")
        try Data("#!/bin/sh\n".utf8).write(to: only)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: only.path)
        XCTAssertEqual(Paths.findExecutable(named: "kinhin-only-tool"), only.path)
    }
}
