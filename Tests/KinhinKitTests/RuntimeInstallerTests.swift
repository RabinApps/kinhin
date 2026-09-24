import XCTest
@testable import KinhinKit

private final class InstallShell: ShellRunning, @unchecked Sendable {
    var calls: [[String]] = []
    var failOn: String?
    func run(_ argv: [String], cwd: URL?, timeout: TimeInterval) async throws -> ShellResult {
        calls.append(argv)
        if let failOn, argv.contains(failOn) { return ShellResult(exitCode: 1, stdout: "", stderr: "boom") }
        return ShellResult(exitCode: 0, stdout: "", stderr: "")
    }
}

final class RuntimeInstallerTests: XCTestCase {
    func testEveryToolHasAtLeastOneOptionWithACommandLine() {
        for tool in InstallableTool.allCases {
            let options = RuntimeInstaller.options(for: tool)
            XCTAssertFalse(options.isEmpty, "\(tool)")
            for option in options {
                XCTAssertFalse(option.commandLine.isEmpty)
                XCTAssertNotNil(option.manualURL, "each option has a manual fallback")
            }
        }
        XCTAssertEqual(RuntimeInstaller.options(for: .docker).map(\.id), ["docker-desktop", "docker-orbstack", "docker-colima"])
    }

    func testCommandLineShowsTheExactCommands() {
        let container = RuntimeInstaller.options(for: .appleContainer)[0]
        XCTAssertEqual(container.commandLine, "brew install container && container system start --enable-kernel-install")
        XCTAssertTrue(RuntimeInstaller.options(for: .tart)[0].commandLine.contains("brew install openai/tools/tart"))
    }

    func testErrorSummaryKeepsTheRealErrorNotTheBrewNoise() {
        let noise = """
        ==> Auto-updating Homebrew...
        Adjust how often this is run with `$HOMEBREW_AUTO_UPDATE_SECS`
        ==> Auto-updated Homebrew!
        Updated 5 taps (heroku/brew, openai/tools).
        ==> New Formulae
        sofka: Kubernetes TUI
        Error: Cask 'container' is unavailable: No Cask with this name exists.
        """
        let summary = summarize(noise)
        XCTAssertEqual(summary, "Error: Cask 'container' is unavailable: No Cask with this name exists.")
        // No explicit error line: fall back to the last few lines, not the first.
        XCTAssertTrue(summarize("a\nb\nc\nd\ne\nf").hasSuffix("f"))
        XCTAssertFalse(summarize("a\nb\nc\nd\ne\nf").hasPrefix("a"))
    }

    func testInstallCommandsUseRealHomebrewNames() {
        // Verified against Homebrew: Apple container is a formula (not a
        // cask); Docker Desktop's cask is docker-desktop.
        XCTAssertEqual(RuntimeInstaller.options(for: .appleContainer)[0].commands, [["brew", "install", "container"]])
        XCTAssertEqual(RuntimeInstaller.options(for: .docker)[0].commands, [["brew", "install", "--cask", "docker-desktop"]])
    }

    func testInstallResolvesBrewToAnAbsolutePathAndRunsInOrder() async throws {
        let shell = InstallShell()
        let option = InstallOption(id: "x", title: "x", detail: "", commands: [["brew", "install", "foo"]], postInstall: [["/bin/echo", "done"]])
        try await RuntimeInstaller.install(option, tool: .docker, shell: shell, brew: "/opt/homebrew/bin/brew", isInstalled: { _ in true })
        XCTAssertEqual(shell.calls, [["/opt/homebrew/bin/brew", "install", "foo"], ["/bin/echo", "done"]],
                       "the process runner needs an absolute path, never a bare 'brew'")
    }

    func testMissingBrewFailsBeforeRunningAnything() async {
        let shell = InstallShell()
        let option = InstallOption(id: "x", title: "x", detail: "", commands: [["brew", "install", "foo"]])
        do { try await RuntimeInstaller.install(option, tool: .docker, shell: shell, brew: nil, isInstalled: { _ in true }); XCTFail() }
        catch { XCTAssertEqual(error as? RuntimeInstallerError, .brewMissing) }
        XCTAssertTrue(shell.calls.isEmpty)
    }

    func testFailureStopsAndReportsTheCommand() async {
        let shell = InstallShell()
        shell.failOn = "install"
        let option = InstallOption(id: "x", title: "x", detail: "", commands: [["brew", "install", "foo"]], postInstall: [["/bin/echo", "never"]])
        do { try await RuntimeInstaller.install(option, tool: .docker, shell: shell, brew: "/b/brew", isInstalled: { _ in true }); XCTFail() }
        catch {
            XCTAssertTrue(error.localizedDescription.contains("brew install foo failed"))
            XCTAssertTrue(error.localizedDescription.contains("boom"))
        }
        XCTAssertEqual(shell.calls.count, 1, "post-install steps are skipped after a failure")
    }

    func testSuccessfulCommandsButToolStillMissingIsReported() async {
        let option = InstallOption(id: "x", title: "x", detail: "", commands: [["/bin/echo"]], needsBrew: false)
        do { try await RuntimeInstaller.install(option, tool: .docker, shell: InstallShell(), brew: nil, isInstalled: { _ in false }); XCTFail() }
        catch { XCTAssertEqual(error as? RuntimeInstallerError, .notInstalledAfterwards(.docker)) }
    }
}
