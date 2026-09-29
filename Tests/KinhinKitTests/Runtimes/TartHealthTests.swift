import Synchronization
import XCTest

@testable import KinhinKit

final class TartHealthTests: XCTestCase {
    // MARK: Fake shell

    /// Scriptable ShellRunning: answers `tart --version` and `log show` probes
    /// from configurable results, recording what it was asked to run.
    final class ScriptedShell: ShellRunning, Sendable {
        private struct State: Sendable {
            var versionResult: ShellResult?
            var versionThrows = false
            var logResult: ShellResult?
            var runArgv: [[String]] = []
        }

        private let state = Mutex(State())

        var versionResult: ShellResult? {
            get { state.withLock { $0.versionResult } }
            set { state.withLock { $0.versionResult = newValue } }
        }
        var versionThrows: Bool {
            get { state.withLock { $0.versionThrows } }
            set { state.withLock { $0.versionThrows = newValue } }
        }
        var logResult: ShellResult? {
            get { state.withLock { $0.logResult } }
            set { state.withLock { $0.logResult = newValue } }
        }
        var runArgv: [[String]] { state.withLock { $0.runArgv } }

        func run(_ argv: [String], cwd: URL?, timeout: TimeInterval) async throws -> ShellResult {
            state.withLock { $0.runArgv.append(argv) }
            if versionThrows, argv.count >= 2, argv[1] == "--version" {
                throw ShellError.launchFailed("permission denied")
            }
            if argv.count >= 2, argv[1] == "--version" {
                return versionResult ?? ShellResult(exitCode: 0, stdout: "tart version 2.32.1", stderr: "")
            }
            if argv.count >= 2, argv[1] == "show" {
                return logResult ?? ShellResult(exitCode: 0, stdout: "", stderr: "")
            }
            return ShellResult(exitCode: 0, stdout: "", stderr: "")
        }
    }

    // A real empty executable file so Paths.findExecutable succeeds and the
    // probe proceeds to the scripted shell.
    private var stubBinaryPath: String!

    override func setUpWithError() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("kinhin-test-tart-\(UUID().uuidString)")
        FileManager.default.createFile(atPath: url.path, contents: Data("#!/bin/sh\n".utf8))
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        stubBinaryPath = url.path
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(atPath: stubBinaryPath)
    }

    private func result(_ code: Int32, stdout: String = "", stderr: String = "") -> ShellResult {
        ShellResult(exitCode: code, stdout: stdout, stderr: stderr)
    }

    // MARK: Classification

    func testHealthyVersionOutput() async {
        let shell = ScriptedShell()
        shell.versionResult = result(0, stdout: "tart version 2.33.0\n")
        let health = await TartHealthProbe(shell: shell, configuredPath: stubBinaryPath).check()
        XCTAssertEqual(health, .healthy)
    }

    func testMissingBinary() async {
        // An override pointing at nothing guarantees "missing" regardless of host.
        let health = await TartHealthProbe(configuredPath: "/nonexistent/kinhin-test-tart").check()
        XCTAssertEqual(health, .missing)
    }

    func testKilledOnLaunchExit137() async {
        let shell = ScriptedShell()
        shell.versionResult = result(137)
        let health = await TartHealthProbe(shell: shell, configuredPath: stubBinaryPath).check()
        XCTAssertEqual(health, .killedOnLaunch)
    }

    func testKilledOnLaunchRawSignal9() async {
        let shell = ScriptedShell()
        shell.versionResult = result(9)
        let health = await TartHealthProbe(shell: shell, configuredPath: stubBinaryPath).check()
        XCTAssertEqual(health, .killedOnLaunch)
    }

    func testKilledOnLaunchViaAMFILogEvenWithPlainExitCode() async {
        let shell = ScriptedShell()
        shell.versionResult = result(1, stderr: "Abort trap")
        shell.logResult = result(0, stdout: "AMFI: Code Signature Invalid: killing tart (platform 13)")
        let health = await TartHealthProbe(shell: shell, configuredPath: stubBinaryPath).check()
        XCTAssertEqual(health, .killedOnLaunch)
    }

    func testBrokenWithStderr() async {
        let shell = ScriptedShell()
        shell.versionResult = result(1, stderr: "dyld: Library not loaded")
        shell.logResult = result(0, stdout: "")
        let health = await TartHealthProbe(shell: shell, configuredPath: stubBinaryPath).check()
        guard case .broken(let reason) = health else {
            return XCTFail("expected .broken, got \(health)")
        }
        XCTAssertTrue(reason.contains("Library not loaded"))
    }

    func testUnverifiableLaunchFallsBackToKilledOnLaunch() async {
        let shell = ScriptedShell()
        shell.versionThrows = true
        shell.logResult = nil
        let health = await TartHealthProbe(shell: shell, configuredPath: stubBinaryPath).check()
        XCTAssertEqual(health, .killedOnLaunch)
    }

    // MARK: Repairs

    func testHealthyHasNoRepairs() {
        XCTAssertTrue(TartHealthProbe.repairs(for: .healthy).isEmpty)
    }

    func testMissingOffersOpenAIInstall() {
        let repairs = TartHealthProbe.repairs(for: .missing)
        XCTAssertEqual(repairs.count, 1)
        XCTAssertTrue(repairs[0].commands.contains(["brew", "install", "openai/tools/tart"]))
    }

    func testKilledOnLaunchOffersCirrusRollbackFirst() {
        let repairs = TartHealthProbe.repairs(for: .killedOnLaunch)
        XCTAssertEqual(repairs.count, 2)
        XCTAssertTrue(repairs[0].title.lowercased().contains("cirrus"))
        XCTAssertTrue(repairs[0].commands.contains(["brew", "install", "cirruslabs/cli/tart"]))
        XCTAssertTrue(repairs[0].commands.contains(["brew", "uninstall", "openai/tools/tart", "openai/tools/softnet"]))
    }

    func testBrokenOffersReinstallBeforeRollback() {
        let repairs = TartHealthProbe.repairs(for: .broken("boom"))
        XCTAssertEqual(repairs.count, 2)
        XCTAssertTrue(repairs[0].commands.contains(["brew", "install", "openai/tools/tart"]))
        XCTAssertTrue(repairs[1].title.lowercased().contains("cirrus"))
    }

    func testCommandLineRendering() {
        let repair = TartHealthProbe.repairs(for: .missing)[0]
        XCTAssertEqual(
            repair.commandLine,
            "brew tap openai/tools && brew trust openai/tools && brew install openai/tools/tart"
        )
    }
}
