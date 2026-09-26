import XCTest

@testable import KinhinKit
@testable import KinhinTestSupport
@testable import kinhin

/// `kinhin setup repair docker|container|tart`: the command core is called
/// directly with a fake shell and host, so no test runs Homebrew or exits.
final class SetupRepairCommandTests: XCTestCase {
    private func host(arm64: Bool = true, memoryGB: Int = 16, macOS: Int = 26) -> HostFacts {
        HostFacts(
            arm64: arm64, memoryGB: memoryGB,
            osVersion: OperatingSystemVersion(majorVersion: macOS, minorVersion: 0, patchVersion: 0))
    }

    func testToolNamesMapToInstallableTools() {
        XCTAssertEqual(SetupRepairCommand.tool(named: "docker"), .docker)
        XCTAssertEqual(SetupRepairCommand.tool(named: "container"), .appleContainer)
        XCTAssertEqual(SetupRepairCommand.tool(named: "tart"), .tart)
        XCTAssertNil(SetupRepairCommand.tool(named: "podman"))
    }

    func testAlreadyInstalledRunsNothing() async throws {
        let shell = FakeShell()
        var lines: [String] = []
        try await SetupRepairCommand.install(
            .docker, method: nil, host: host(), shell: shell, brew: "/b/brew", isInstalled: { _ in true },
            output: { lines.append($0) })
        XCTAssertEqual(lines, ["Docker is already installed"])
        XCTAssertTrue(shell.calls.isEmpty)
    }

    func testDockerDefaultsToTheFirstSupportedMethod() async throws {
        let shell = FakeShell()
        var lines: [String] = []
        var checks = 0
        try await SetupRepairCommand.install(
            .docker, method: nil, host: host(), shell: shell, brew: "/b/brew",
            isInstalled: { _ in
                checks += 1
                return checks > 1  // missing before, present after
            },
            output: { lines.append($0) })
        XCTAssertEqual(shell.calls, [["/b/brew", "install", "--cask", "docker-desktop"]])
        XCTAssertTrue(lines.first?.contains("brew install --cask docker-desktop") ?? false, "prints the command first")
    }

    func testMethodPicksTheOption() async throws {
        let shell = FakeShell()
        var checks = 0
        try await SetupRepairCommand.install(
            .docker, method: "orbstack", host: host(), shell: shell, brew: "/b/brew",
            isInstalled: { _ in
                checks += 1
                return checks > 1
            }, output: { _ in })
        XCTAssertEqual(shell.calls, [["/b/brew", "install", "--cask", "orbstack"]])
    }

    func testLowMemorySkipsDockerDesktopByDefault() async throws {
        let shell = FakeShell()
        var checks = 0
        try await SetupRepairCommand.install(
            .docker, method: nil, host: host(memoryGB: 2), shell: shell, brew: "/b/brew",
            isInstalled: { _ in
                checks += 1
                return checks > 1
            }, output: { _ in })
        XCTAssertEqual(shell.calls.first, ["/b/brew", "install", "--cask", "orbstack"])
    }

    func testOlderMacOSWarnsBeforeDockerDesktop() async throws {
        var warnings: [String] = []
        var checks = 0
        try await SetupRepairCommand.install(
            .docker, method: "desktop", host: host(macOS: 14), shell: FakeShell(), brew: "/b/brew",
            isInstalled: { _ in
                checks += 1
                return checks > 1
            }, output: { _ in }, warning: { warnings.append($0) })
        XCTAssertEqual(warnings.count, 1)
        XCTAssertTrue(warnings[0].contains("macOS 15"))
    }

    func testUnsupportedMacFailsBeforeRunningAnything() async {
        let shell = FakeShell()
        do {
            try await SetupRepairCommand.install(
                .appleContainer, method: nil, host: host(arm64: false), shell: shell, brew: "/b/brew",
                isInstalled: { _ in false }, output: { _ in })
            XCTFail("expected a throw")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("Apple silicon"))
            XCTAssertEqual(CLIExit(error), .runtime, "install failures exit as runtime errors")
        }
        XCTAssertTrue(shell.calls.isEmpty)
    }

    func testDesktopMethodOnALowMemoryMacIsRefused() async {
        do {
            try await SetupRepairCommand.install(
                .docker, method: "desktop", host: host(memoryGB: 2), shell: FakeShell(), brew: "/b/brew",
                isInstalled: { _ in false }, output: { _ in })
            XCTFail("expected a throw")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("4 GB"))
        }
    }

    func testSetupStatusPointsAtTheRepairCommand() {
        XCTAssertEqual(SetupStatusCommand.cliCommand(for: "install_docker"), "kinhin setup repair docker")
        XCTAssertEqual(SetupStatusCommand.cliCommand(for: "install_container_cli"), "kinhin setup repair container")
        XCTAssertNil(SetupStatusCommand.cliCommand(for: "enter_token"))
    }
}
