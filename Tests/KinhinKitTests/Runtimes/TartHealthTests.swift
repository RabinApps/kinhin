import Synchronization
import XCTest

@testable import KinhinKit
@testable import KinhinTestSupport

final class TartHealthTests: XCTestCase {
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

    private func shell(
        version: ShellResult? = nil, versionThrows: Bool = false, log: ShellResult? = nil
    ) -> FakeShell {
        let shell = FakeShell()
        if versionThrows {
            // The probe catches launch failures itself, so model the throw
            // with the shared throw hook on a version-shaped argv match.
            shell.scriptedResponses = [
                ScriptedResponse(whenContainsThrowing: "--version", reason: "permission denied")
            ]
        } else {
            shell.scriptedResponses = [
                ScriptedResponse(
                    whenContainsAll: [stubBinaryPath, "--version"],
                    version ?? result(0, stdout: "tart version 2.32.1"))
            ]
        }
        if let log {
            shell.scriptedResponses.append(ScriptedResponse(whenContains: "show", log))
        }
        return shell
    }

    // MARK: Classification

    func testHealthyVersionOutput() async {
        let health = await TartHealthProbe(
            shell: shell(version: result(0, stdout: "tart version 2.33.0\n")), configuredPath: stubBinaryPath
        )
        .check()
        XCTAssertEqual(health, .healthy)
    }

    func testHealthyBareVersionOutput() async {
        // Tart 2.40+ prints just the version number for `--version`.
        let health = await TartHealthProbe(
            shell: shell(version: result(0, stdout: "2.40.1\n")), configuredPath: stubBinaryPath
        )
        .check()
        XCTAssertEqual(health, .healthy)
    }

    func testMissingBinary() async {
        // An override pointing at nothing guarantees "missing" regardless of host.
        let health = await TartHealthProbe(configuredPath: "/nonexistent/kinhin-test-tart").check()
        XCTAssertEqual(health, .missing)
    }

    func testKilledOnLaunchExit137() async {
        let health = await TartHealthProbe(shell: shell(version: result(137)), configuredPath: stubBinaryPath).check()
        XCTAssertEqual(health, .killedOnLaunch)
    }

    func testKilledOnLaunchRawSignal9() async {
        let health = await TartHealthProbe(shell: shell(version: result(9)), configuredPath: stubBinaryPath).check()
        XCTAssertEqual(health, .killedOnLaunch)
    }

    func testKilledOnLaunchViaAMFILogEvenWithPlainExitCode() async {
        let health = await TartHealthProbe(
            shell: shell(
                version: result(1, stderr: "Abort trap"),
                log: result(0, stdout: "AMFI: Code Signature Invalid: killing tart (platform 13)")
            ), configuredPath: stubBinaryPath
        ).check()
        XCTAssertEqual(health, .killedOnLaunch)
    }

    func testBrokenWithStderr() async {
        let health = await TartHealthProbe(
            shell: shell(version: result(1, stderr: "dyld: Library not loaded"), log: result(0)),
            configuredPath: stubBinaryPath
        ).check()
        guard case .broken(let reason) = health else {
            return XCTFail("expected .broken, got \(health)")
        }
        XCTAssertTrue(reason.contains("Library not loaded"))
    }

    func testUnverifiableLaunchFallsBackToKilledOnLaunch() async {
        let health = await TartHealthProbe(
            shell: shell(versionThrows: true, log: nil), configuredPath: stubBinaryPath
        ).check()
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
