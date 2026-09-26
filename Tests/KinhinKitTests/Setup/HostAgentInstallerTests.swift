import XCTest

@testable import KinhinKit
@testable import KinhinTestSupport

final class HostAgentInstallerTests: XCTestCase {
    private var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("kinhin-host-agent-\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)  // scratch dir; a leftover is harmless
    }

    private func installer(_ shell: FakeShell, arm64: Bool = true) -> HostAgentInstaller {
        HostAgentInstaller(shell: shell, agentDir: dir, arm64: arm64, latestVersion: { "2.999.0" })
    }

    private func plantAgent() throws {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: dir.appendingPathComponent("config.sh").path, contents: Data())
    }

    func testDownloadURLPicksArchitecture() {
        let shell = FakeShell()
        XCTAssertTrue(
            installer(shell, arm64: true).downloadURL(version: "2.999.0")
                .hasSuffix("/v2.999.0/actions-runner-osx-arm64-2.999.0.tar.gz"))
        XCTAssertTrue(
            installer(shell, arm64: false).downloadURL(version: "2.999.0")
                .hasSuffix("/v2.999.0/actions-runner-osx-x64-2.999.0.tar.gz"))
    }

    func testInstallRunsDownloadInAgentDirAndReportsVersion() async throws {
        let shell = FakeShell()
        try plantAgent()  // the fake shell can't unpack; pretend tar did
        let version = try await installer(shell).install()
        XCTAssertEqual(version, "2.999.0")
        XCTAssertEqual(shell.calls.count, 1)
        XCTAssertEqual(shell.calls[0][0], "/bin/bash")
        XCTAssertTrue(shell.calls[0][2].contains("actions-runner-osx-arm64-2.999.0.tar.gz"))
    }

    func testInstallFailsWhenDownloadFails() async {
        let shell = FakeShell()
        shell.failAll = "curl: (22) 404"
        do {
            _ = try await installer(shell).install()
            XCTFail("expected failure")
        } catch let error as ImageError {
            XCTAssertTrue(error.localizedDescription.contains("404"))
        } catch {
            XCTFail("unexpected \(error)")
        }
    }

    func testInstallFailsWhenAgentMissingAfterUnpack() async {
        do {
            _ = try await installer(FakeShell()).install()
            XCTFail("expected failure")
        } catch let error as ImageError {
            XCTAssertTrue(error.localizedDescription.contains("config.sh"))
        } catch {
            XCTFail("unexpected \(error)")
        }
    }

    func testIsInstalledTracksConfigScript() throws {
        let sut = installer(FakeShell())
        XCTAssertFalse(sut.isInstalled)
        try plantAgent()
        XCTAssertTrue(sut.isInstalled)
    }
}
