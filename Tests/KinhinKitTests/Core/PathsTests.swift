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

    /// Well-known installer locations (Docker Desktop's `~/.docker/bin`) are
    /// consulted after the trusted directories and `PATH`, so every probe
    /// agrees with the engine on which binary exists — and a choice is never
    /// changed for anything already found earlier.
    func testExtraCandidateDirectoriesAreConsultedLast() throws {
        let foundDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("kinhin-paths-extra-\(UUID().uuidString)")
        let shadowDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("kinhin-paths-extra-path-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: foundDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: shadowDir, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: foundDir)  // test cleanup
            try? FileManager.default.removeItem(at: shadowDir)
        }

        // A tool only present in the extra location is found there.
        let extraOnly = foundDir.appendingPathComponent("kinhin-extra-tool")
        try Data("#!/bin/sh\n".utf8).write(to: extraOnly)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: extraOnly.path)
        XCTAssertEqual(
            Paths.findExecutable(named: "kinhin-extra-tool", extraDirectories: [foundDir.path]), extraOnly.path)

        // PATH still wins over the extra location: trusted > PATH > extras.
        let onPath = shadowDir.appendingPathComponent("kinhin-dup-tool")
        let inExtra = foundDir.appendingPathComponent("kinhin-dup-tool")
        for file in [onPath, inExtra] {
            try Data("#!/bin/sh\n".utf8).write(to: file)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: file.path)
        }
        let oldPath = ProcessInfo.processInfo.environment["PATH"]
        setenv("PATH", "\(shadowDir.path):/usr/bin", 1)
        defer { if let oldPath { setenv("PATH", oldPath, 1) } else { unsetenv("PATH") } }
        XCTAssertEqual(
            Paths.findExecutable(named: "kinhin-dup-tool", extraDirectories: [foundDir.path]), onPath.path)
    }

    /// The wiring: docker alone gets the Docker Desktop directory, and tart
    /// stays strict (trusted dirs + PATH only — its override is `tart_path:`),
    /// so a job-writable home directory can never shadow the fleet's binary.
    func testOnlyDockerHasExtraCandidateDirectories() {
        XCTAssertEqual(Paths.extraCandidateDirectories["docker"], [NSHomeDirectory() + "/.docker/bin"])
        XCTAssertNil(Paths.extraCandidateDirectories["tart"])
        XCTAssertNil(Paths.extraCandidateDirectories["container"])
    }
}
