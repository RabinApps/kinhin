import XCTest

@testable import KinhinKit
@testable import KinhinTestSupport

final class ContainerCommitTests: XCTestCase {
    private func options() -> LinuxImageOptions {
        LinuxImageOptions(
            image: "ubuntu:24.04", target: "out-image", hasGitHubToken: true, hasGiteaToken: false,
            hasGitLabToken: false, hasBuildkiteToken: false, hasAzureDevOpsToken: false)
    }

    func testCommitExportsTheScratchFilesystemThenBuildsFromScratch() async throws {
        let shell = FakeShell()
        _ = try await ContainerImagePreparer(shell: shell).prepare(options(), versions: .init(github: "1", gitea: "1"))
        let calls = shell.calls
        let export = try XCTUnwrap(calls.firstIndex { $0.contains("export") }, "\(calls)")
        let build = try XCTUnwrap(calls.firstIndex { $0.contains("build") }, "\(calls)")
        XCTAssertLessThan(export, build)
        XCTAssertTrue(calls[export].contains("--output"))
        XCTAssertEqual(calls[build].dropFirst().prefix(3), ["build", "--tag", "out-image"])
        XCTAssertFalse(calls.contains { $0.contains("FROM") }, "the Dockerfile is a file, not an argument")
    }

    func testExportFailureIsReportedWithItsReason() async {
        let shell = FakeShell()
        shell.failOn = "export"
        do {
            _ = try await ContainerImagePreparer(shell: shell).prepare(
                options(), versions: .init(github: "1", gitea: "1"))
            XCTFail("expected a failure")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("container export failed"), error.localizedDescription)
            XCTAssertTrue(error.localizedDescription.contains("boom"), error.localizedDescription)
        }
        XCTAssertFalse(shell.calls.contains { $0.contains("build") }, "no build after a failed export")
    }
}
