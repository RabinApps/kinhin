import XCTest

@testable import KinhinKit

/// Runner agents started over SSH pass that session's PATH to every job, and a non-login macOS SSH session has only
/// `/usr/bin:/bin:/usr/sbin:/sbin`, so a Tart macOS job could not find `kinhin-toolchain` (e2e per-job install).
final class GuestLoginPathPreludeTests: XCTestCase {
    func testThePreludeGivesASystemOnlyPathTheLoginDirectories() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("kn-path-\(UUID().uuidString)")
        let shims = home.appendingPathComponent(".local/share/mise/shims")
        try FileManager.default.createDirectory(at: shims, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = ["-c", RunnerBootstrap.guestLoginPathPrelude + "\necho \"$PATH\""]
        process.environment = ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "HOME": home.path]
        let out = Pipe()
        process.standardOutput = out
        try process.run()
        process.waitUntilExit()
        let path = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let entries = path.split(separator: ":").map(String.init)

        XCTAssertEqual(process.terminationStatus, 0)
        XCTAssertTrue(entries.contains("/usr/local/bin"), "kinhin-toolchain lives there: \(path)")
        XCTAssertTrue(entries.contains(shims.path), "mise shims that exist are added: \(path)")
        XCTAssertTrue(entries.contains("/usr/bin"), "the system directories stay: \(path)")
        XCTAssertEqual(entries.count, Set(entries).count, "no duplicates: \(path)")
    }
}
