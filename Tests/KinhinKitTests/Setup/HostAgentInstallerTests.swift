import XCTest

@testable import KinhinKit
@testable import KinhinTestSupport

final class HostAgentInstallerTests: XCTestCase {
    private var dir: URL!
    private let versions = RunnerVersionResolver.Versions(github: "2.999.0", gitea: "9.9.9")

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("kinhin-host-agent-\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)  // scratch dir; a leftover is harmless
    }

    private func installer(_ shell: FakeShell, arm64: Bool = true) -> HostAgentInstaller {
        HostAgentInstaller(shell: shell, agentDir: dir, arm64: arm64, latestVersions: { self.versions })
    }

    private func plant(github: Bool = false, gitea: Bool = false) throws {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        if github {
            FileManager.default.createFile(atPath: dir.appendingPathComponent("config.sh").path, contents: Data())
        }
        if gitea {
            let path = dir.appendingPathComponent("gitea-runner").path
            FileManager.default.createFile(atPath: path, contents: Data(), attributes: [.posixPermissions: 0o755])
        }
    }

    func testScriptDownloadsBothAgentsVerifiedForThisArchitecture() {
        let arm = installer(FakeShell(), arm64: true).installScript(versions)
        XCTAssertTrue(arm.contains("actions-runner-osx-arm64-2.999.0.tar.gz"))
        XCTAssertTrue(arm.contains("gitea-runner-9.9.9-darwin-arm64.xz"))
        XCTAssertTrue(arm.contains("refusing to install"), "downloads are digest-verified")
        let intel = installer(FakeShell(), arm64: false).installScript(versions)
        XCTAssertTrue(intel.contains("actions-runner-osx-x64-2.999.0.tar.gz"))
        XCTAssertTrue(intel.contains("gitea-runner-9.9.9-darwin-amd64.xz"))
    }

    func testScriptSkipsAgentsAlreadyInstalled() throws {
        try plant(github: true)
        let script = installer(FakeShell()).installScript(versions)
        XCTAssertFalse(script.contains("actions-runner-osx"))
        XCTAssertTrue(script.contains("gitea-runner-9.9.9"))
    }

    func testInstallRunsInAgentDirAndReportsVersions() async throws {
        let shell = FakeShell()
        try plant(github: true, gitea: true)  // the fake shell can't unpack; pretend it did
        let result = try await installer(shell).install()
        XCTAssertEqual(result, versions)
        XCTAssertEqual(shell.calls.count, 1)
        XCTAssertEqual(shell.calls[0][0], "/bin/bash")
    }

    func testInstallFailsWhenDownloadFails() async {
        let shell = FakeShell()
        shell.failAll = "error: SHA-256 mismatch"
        do {
            _ = try await installer(shell).install()
            XCTFail("expected failure")
        } catch let error as ImageError {
            XCTAssertTrue(error.localizedDescription.contains("SHA-256"))
        } catch {
            XCTFail("unexpected \(error)")
        }
    }

    func testInstallFailsWhenAnAgentIsMissingAfterUnpack() async throws {
        try plant(github: true)
        do {
            _ = try await installer(FakeShell()).install()
            XCTFail("expected failure")
        } catch let error as ImageError {
            XCTAssertTrue(error.localizedDescription.contains("gitea-runner"))
        } catch {
            XCTFail("unexpected \(error)")
        }
    }

    func testIsInstalledNeedsBothAgents() throws {
        let sut = installer(FakeShell())
        XCTAssertFalse(sut.isInstalled)
        try plant(github: true)
        XCTAssertFalse(sut.isInstalled, "the GitHub agent alone is not enough")
        try plant(github: true, gitea: true)
        XCTAssertTrue(sut.isInstalled)
    }
}
