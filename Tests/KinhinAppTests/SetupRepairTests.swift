import XCTest
@testable import KinhinKit
@testable import kinhin_app

/// Local recording shell double — test targets don't share helpers, so the
/// KinhinKitTests double is copied (trimmed) here rather than exported.
private final class RecordingShell: ShellRunning, @unchecked Sendable {
    private let lock = NSLock()
    private(set) var argvs: [[String]] = []
    var result = ShellResult(exitCode: 0, stdout: "", stderr: "")

    func run(_ argv: [String], cwd: URL?, timeout: TimeInterval) async throws -> ShellResult {
        lock.lock(); argvs.append(argv); lock.unlock()
        return result
    }
}

@MainActor
final class SetupRepairTests: XCTestCase {
    private let install = TartRepair(
        title: "Install tart via the OpenAI tap",
        commands: [
            ["brew", "tap", "openai/tools"],
            ["brew", "trust", "openai/tools"],
            ["brew", "install", "openai/tools/tart"],
        ]
    )

    // MARK: command execution

    func testRepairRunsEveryCommandInOrder() async throws {
        let shell = RecordingShell()
        try await SetupWindowController.run(install, shell: shell)

        XCTAssertEqual(shell.argvs.count, 3)
        XCTAssertEqual(shell.argvs[0], ["brew", "tap", "openai/tools"])
        XCTAssertEqual(shell.argvs[1], ["brew", "trust", "openai/tools"])
        XCTAssertEqual(shell.argvs[2], ["brew", "install", "openai/tools/tart"])
    }

    func testRepairThrowsWithStderrWhenACommandFails() async {
        let shell = RecordingShell()
        shell.result = ShellResult(exitCode: 1, stdout: "", stderr: "brew: no such tap")

        do {
            try await SetupWindowController.run(install, shell: shell)
            XCTFail("a failed command must stop the repair with an error")
        } catch {
            XCTAssertTrue("\(error)".contains("brew: no such tap"), "the user must see the tool's own error: \(error)")
        }
        // Fail fast: later commands never run after a failure.
        XCTAssertEqual(shell.argvs.count, 1)
    }

    func testRepairFallsBackToTheCommandWhenStderrIsEmpty() async {
        let shell = RecordingShell()
        shell.result = ShellResult(exitCode: 2, stdout: "", stderr: "")

        do {
            try await SetupWindowController.run(install, shell: shell)
            XCTFail("expected an error")
        } catch {
            // With empty stderr the failing command itself is the message.
            XCTAssertTrue("\(error)".contains("brew failed: brew tap openai/tools"), "\(error)")
        }
    }

    func testRepairCommandlineJoendsWithAnd() {
        XCTAssertEqual(install.commandLine,
                       "brew tap openai/tools && brew trust openai/tools && brew install openai/tools/tart")
    }

    // MARK: repair plans (same mapping the app's buttons rely on)

    func testRepairsForHealthyIsEmpty() {
        XCTAssertTrue(TartHealthProbe.repairs(for: .healthy).isEmpty)
    }

    func testRollbackIsFirstForGatekeeperKills() {
        let plans = TartHealthProbe.repairs(for: .killedOnLaunch)
        XCTAssertEqual(plans.first?.commands.first, ["brew", "uninstall", "openai/tools/tart", "openai/tools/softnet"])
    }

    func testMissingTartRepairsInstallFirst() {
        let plans = TartHealthProbe.repairs(for: .missing)
        XCTAssertEqual(plans.first?.commands.first, ["brew", "tap", "openai/tools"])
    }
}
