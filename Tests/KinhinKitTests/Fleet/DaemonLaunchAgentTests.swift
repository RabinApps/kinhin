import XCTest

@testable import KinhinKit
@testable import KinhinTestSupport

/// `kinhin daemon install`: the launchctl call and the debug-build refusal.
final class DaemonLaunchAgentTests: XCTestCase {
    func testLoadRunsLaunchctlByItsAbsolutePath() async throws {
        let shell = FakeShell()
        _ = try await Daemon.loadAgent(shell: shell)
        XCTAssertEqual(shell.calls, [["/bin/launchctl", "load", Daemon.agentPlistPath().path]])
    }

    func testASymlinkIntoADebugBuildIsADebugBuild() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("kinhin-agent-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let binary = root.appendingPathComponent("repo/.build/debug/kinhin")
        try FileManager.default.createDirectory(
            at: binary.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data().write(to: binary)
        let link = root.appendingPathComponent("bin/kinhin")
        try FileManager.default.createDirectory(at: link.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: binary)

        XCTAssertFalse(Daemon.isDebugBuild(link.path), "the link's own path hides the build")
        XCTAssertTrue(Daemon.isDebugBuild(Daemon.launchAgentBinary(argv0: link.path)))
    }

    func testReleaseAndAppBinariesAreNotDebugBuilds() {
        XCTAssertFalse(Daemon.isDebugBuild("/Applications/kinhin.app/Contents/Resources/bin/kinhin"))
        XCTAssertFalse(Daemon.isDebugBuild("/Users/me/kinhin/.build/release/kinhin"))
        XCTAssertTrue(Daemon.isDebugBuild("/Users/me/kinhin/.build/arm64-apple-macosx/debug/kinhin"))
    }

    /// `Shell` runs argv[0] as a file path: a bare command name resolves
    /// against the working directory and fails (`launchctl` once did).
    func testNoSourceRunsABareExecutableName() throws {
        let sources = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Sources")
        let pattern = try NSRegularExpression(pattern: #"\.run\(\s*\["([^"/$\\][^"]*)""#)
        var offenders: [String] = []
        let files = FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil)
        while let url = files?.nextObject() as? URL {
            guard url.pathExtension == "swift" else { continue }
            let text = try String(contentsOf: url, encoding: .utf8)
            let range = NSRange(text.startIndex..., in: text)
            for match in pattern.matches(in: text, range: range) {
                if let name = Range(match.range(at: 1), in: text) {
                    offenders.append("\(url.lastPathComponent): \(text[name])")
                }
            }
        }
        XCTAssertFalse(files == nil, "Sources/ not found from \(#filePath)")
        XCTAssertEqual(offenders, [], "use an absolute path for argv[0]")
    }
}
