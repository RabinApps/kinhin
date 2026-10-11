import XCTest

/// `scripts/install.sh` refuses any release tag that does not match its pattern. It once
/// rejected `v0.0.1-beta-1` (the suffix allowed no second hyphen), so the very first
/// `curl … | bash` against the first release failed. Runs the script's own regex in bash.
final class InstallScriptTagTests: XCTestCase {
    private func pattern() throws -> String {
        let script = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("scripts/install.sh")
        let text = try String(contentsOf: script, encoding: .utf8)
        let line = try XCTUnwrap(
            text.split(separator: "\n").first { $0.contains("unexpected release tag") }, "tag check not found")
        let start = try XCTUnwrap(line.range(of: "=~ "))
        let end = try XCTUnwrap(line.range(of: " ]]"))
        return String(line[start.upperBound..<end.lowerBound])
    }

    private func accepts(_ tag: String) throws -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = ["-c", "[[ \"$1\" =~ \(try pattern()) ]]", "bash", tag]
        try process.run()
        process.waitUntilExit()
        return process.terminationStatus == 0
    }

    func testReleaseTagsTheProjectPublishesAreAccepted() throws {
        for tag in ["v0.0.1-beta-1", "v0.1.0", "v1.2.3-rc-2", "v0.2.0-beta"] {
            XCTAssertTrue(try accepts(tag), tag)
        }
    }

    func testAnythingElseIsRefused() throws {
        for tag in ["v1.0", "1.0.0", "v1.0.0;rm -rf /", "v1.0.0-../x", "v1.0.0 extra", ""] {
            XCTAssertFalse(try accepts(tag), tag)
        }
    }
}
