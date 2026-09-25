import XCTest

@testable import KinhinKit

/// Covers the Command Line Tools probe: shell-output parsing, version
/// comparison, and the full state matrix. The shell is stubbed, so no test
/// touches the real machine.
final class DevToolsTests: XCTestCase {
    // MARK: Stub shell

    /// Answers the probe's `/bin/bash -c <command>` calls from scripted
    /// responses keyed by a substring of the command line.
    private struct ScriptedShell: ShellRunning {
        var receipt: ShellResult
        var selected: ShellResult
        var productVersion: String

        func run(_ argv: [String], cwd: URL?, timeout: TimeInterval) async throws -> ShellResult {
            let command = argv.count >= 3 ? argv[2] : ""
            if command.contains("pkg-info=com.apple.pkg.CLTools_Executables") {
                return receipt
            }
            if command.contains("xcode-select") {
                return selected
            }
            if command.contains("sw_vers") {
                return ShellResult(exitCode: 0, stdout: productVersion + "\n", stderr: "")
            }
            return ShellResult(exitCode: 1, stdout: "", stderr: "unexpected command: \(command)")
        }
    }

    private func receipt(_ version: String) -> ShellResult {
        ShellResult(
            exitCode: 0,
            stdout: "package-id: com.apple.pkg.CLTools_Executables\nversion: \(version)\nvolume: /\n",
            stderr: ""
        )
    }

    private func makeProbe(
        receipt receiptResult: ShellResult? = nil,
        selected selectedResult: ShellResult? = nil,
        productVersion: String = "27.0"
    ) -> CLTProbe {
        CLTProbe(
            shell: ScriptedShell(
                receipt: receiptResult ?? receipt("27.0.0.0.0"),
                selected: selectedResult
                    ?? ShellResult(exitCode: 0, stdout: "/Library/Developer/CommandLineTools\n", stderr: ""),
                productVersion: productVersion
            )
        )
    }

    // MARK: Version math

    func testDisplayVersionStripsBuildSuffix() {
        XCTAssertEqual(CLTProbe.displayVersion("26.6.0.0.1781586589"), "26.6.0")
        XCTAssertEqual(CLTProbe.displayVersion("27.0"), "27.0")
        XCTAssertEqual(CLTProbe.displayVersion("27"), "27")
    }

    func testVersionComparisonMatrix() {
        XCTAssertTrue(CLTProbe.isVersion("27.0", atLeast: "27.0"))
        XCTAssertTrue(CLTProbe.isVersion("27.1", atLeast: "27.0"))
        XCTAssertTrue(CLTProbe.isVersion("26.6.1", atLeast: "26.6"))
        XCTAssertFalse(CLTProbe.isVersion("26.6", atLeast: "27.0"))
        XCTAssertFalse(CLTProbe.isVersion("26", atLeast: "26.0.1"))
        XCTAssertFalse(CLTProbe.isVersion("a.b", atLeast: "1.0"))
    }

    // MARK: State matrix

    func testUpToDateCLTIsOK() async {
        let state = await makeProbe(
            receipt: receipt("27.0.0.0.1234"),
            productVersion: "27.0"
        ).check()
        XCTAssertEqual(state, .ok(version: "27.0.0"))
        XCTAssertTrue(state.isOK)
    }

    func testOutdatedCLTWhenOlderThanMacOS() async {
        // This machine's real shape at the time of writing: CLT 26.6, macOS 27.0.
        let state = await makeProbe(
            receipt: receipt("26.6.0.0.1781586589"),
            productVersion: "27.0"
        ).check()
        XCTAssertEqual(state, .outdated(version: "26.6.0", macOSVersion: "27.0"))
        XCTAssertFalse(state.isOK)
        XCTAssertTrue(state.detail.contains("Homebrew will refuse"))
    }

    func testMissingReceiptMeansMissing() async {
        let state = await makeProbe(
            receipt: ShellResult(exitCode: 1, stdout: "", stderr: "No receipt for com.apple.pkg.CLTools_Executables")
        ).check()
        XCTAssertEqual(state, .missing)
        XCTAssertFalse(state.isOK)
    }

    func testBrokenSelectionWithReceiptMeansUnselected() async {
        let state = await makeProbe(
            receipt: receipt("27.0.0.0.0"),
            selected: ShellResult(exitCode: 0, stdout: "error: unable to get active developer directory\n", stderr: "")
        ).check()
        XCTAssertEqual(state, .unselected)
        XCTAssertFalse(state.isOK)
    }

    func testMalformedReceiptMeansMissing() async {
        let state = await makeProbe(
            receipt: ShellResult(exitCode: 0, stdout: "package-id: com.apple.pkg.CLTools_Executables\n", stderr: "")
        ).check()
        XCTAssertEqual(state, .missing)
    }

    // MARK: Repair constants

    func testRepairCommandUsesSudoXcodeSelectPath() {
        XCTAssertTrue(CLTRepair.commandLine.contains("sudo xcode-select --install"))
        XCTAssertTrue(CLTRepair.commandLine.contains("rm -rf /Library/Developer/CommandLineTools"))
        XCTAssertFalse(CLTRepair.fallbackHint.isEmpty)
    }

    // MARK: Checklist integration

    func testCLTOutdatedBlocksTartInstallInChecklist() async {
        // The exact scenario that bit on a real machine: CLT outdated while
        // everything else is fine — the fleet must NOT report ready, and the
        // row must carry the fix action.
        var cfg = kinhinConfig.default
        cfg.repo = "acme/widgets"
        let computer = SetupStatusComputer(
            host: HostResources(logicalCores: 10, memoryGB: 64, freeDiskGB: 120, arm64: true),
            clt: .outdated(version: "26.6", macOSVersion: "27.0"),
            tartHealth: .healthy,
            tartList: [
                TartVM(name: "tahoe-base", source: "ghcr.io/cirruslabs/macos-tahoe-base:latest", status: "suspended")
            ],
            config: .loaded(cfg),
            tokenStored: true
        )
        let status = await computer.compute()
        let cltRow = status.checks.first { $0.id == "clt" }
        XCTAssertEqual(cltRow?.ok, false)
        XCTAssertEqual(cltRow?.action, "fix_clt")
        XCTAssertEqual(status.ready, false, "outdated CLT must block readiness")
    }
}
