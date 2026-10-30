import XCTest

@testable import KinhinKit
@testable import KinhinTestSupport

/// `kinhin daemon install`: the launchctl call and the debug-build refusal.
final class DaemonLaunchAgentTests: XCTestCase {
    func testLoadBootsOutARunningAgentThenLoadsByAbsolutePath() async throws {
        let shell = FakeShell()
        shell.scriptedResponses = [
            ScriptedResponse(
                whenContains: "print",
                ShellResult(
                    exitCode: 0, stdout: "gui/501/com.kinhin.daemon = {\n\tstate = running\n\tlast exit code = 0\n}",
                    stderr: ""))
        ]
        _ = try await Daemon.loadAgent(shell: shell)
        let plist = Daemon.agentPlistPath().path
        XCTAssertEqual(
            shell.calls,
            [
                ["/bin/launchctl", "bootout", "gui/\(getuid())", plist],
                ["/bin/launchctl", "bootstrap", "gui/\(getuid())", plist],
                ["/bin/launchctl", "print", "gui/\(getuid())/\(Daemon.label)"],
            ],
            "a re-install restarts the daemon and verifies launchd reports it healthy")
    }

    func testAFailedBootoutOfALoadedAgentThrowsInsteadOfKeepingTheOldDaemon() async throws {
        let shell = FakeShell()
        shell.scriptedResponses = [
            ScriptedResponse(whenContains: "bootout", ShellResult(exitCode: 5, stdout: "", stderr: "I/O error")),
            ScriptedResponse(
                whenContains: "print",
                ShellResult(
                    exitCode: 0, stdout: "gui/501/com.kinhin.daemon = {\n\tstate = running\n}", stderr: "")),
        ]
        do {
            _ = try await Daemon.loadAgent(shell: shell)
            XCTFail("a still-loaded agent must not be silently replaced")
        } catch let error as Daemon.DaemonError {
            XCTAssertEqual(error, .bootoutFailed("I/O error"))
        }
        XCTAssertFalse(shell.calls.contains { $0.contains("bootstrap") }, "nothing is bootstrapped over the old daemon")
    }

    func testAFailedBootoutOfAnAgentThatIsNotLoadedStillLoads() async throws {
        let shell = FakeShell()
        shell.responses = [
            ShellResult(exitCode: 3, stdout: "", stderr: "No such process"),
            ShellResult(exitCode: 113, stdout: "", stderr: "not found"),
            ShellResult(exitCode: 0, stdout: "", stderr: ""),
            ShellResult(
                exitCode: 0, stdout: "gui/501/com.kinhin.daemon = {\n\tstate = running\n\tlast exit code = 0\n}",
                stderr: ""),
        ]
        let result = try await Daemon.loadAgent(shell: shell)
        XCTAssertTrue(result.succeeded)
        XCTAssertEqual(shell.calls[2][1], "bootstrap")
        XCTAssertEqual(shell.calls[3][1], "print")
    }

    func testBootstrapFailsIfLaunchdReportsTheDaemonExited() async throws {
        let shell = FakeShell()
        shell.scriptedResponses = [
            ScriptedResponse(
                whenContains: "print",
                ShellResult(
                    exitCode: 0, stdout: "gui/501/com.kinhin.daemon = {\n\tstate = waiting\n\tlast exit code = 78\n}",
                    stderr: ""))
        ]
        do {
            _ = try await Daemon.loadAgent(shell: shell)
            XCTFail("a bootstrap success does not prove the daemon stayed running")
        } catch let error as Daemon.DaemonError {
            guard case .agentStartFailed(let reason) = error else {
                return XCTFail("expected agentStartFailed, got \(error)")
            }
            XCTAssertTrue(reason.contains("state = waiting"), reason)
        }
    }

    func testLaunchAgentHealthRequiresRunningStateAndZeroLastExitCode() {
        XCTAssertTrue(Daemon.launchAgentStatusIsHealthy("state = running\nlast exit code = 0"))
        XCTAssertFalse(Daemon.launchAgentStatusIsHealthy("state = waiting\nlast exit code = 0"))
        XCTAssertFalse(Daemon.launchAgentStatusIsHealthy("state = running\nlast exit code = 78"))
        // launchctl annotates some codes (`78: EX_CONFIG`): the annotated
        // value still names the failing status, and an unreadable line is no
        // evidence of a healthy agent either.
        XCTAssertFalse(Daemon.launchAgentStatusIsHealthy("state = running\nlast exit code = 78: EX_CONFIG"))
        XCTAssertFalse(Daemon.launchAgentStatusIsHealthy("state = running\nlast exit code = EX_CONFIG"))
        // A job that has never exited yet reports the sentinel instead of a
        // code; with `state = running` that is a healthy start, not a failure.
        XCTAssertTrue(Daemon.launchAgentStatusIsHealthy("state = running\nlast exit code = (never exited)"))
    }

    func testExitCodeFromReadsPlainAndAnnotatedFragments() {
        XCTAssertEqual(Daemon.exitCode(from: "78"), 78)
        XCTAssertEqual(Daemon.exitCode(from: "78: EX_CONFIG"), 78)
        XCTAssertEqual(Daemon.exitCode(from: "26768: receiver terminated strangely"), 26768)
        XCTAssertNil(Daemon.exitCode(from: "EX_CONFIG"))
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
