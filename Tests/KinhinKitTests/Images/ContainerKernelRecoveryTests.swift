import XCTest

@testable import KinhinKit
@testable import KinhinTestSupport

final class ContainerKernelRecoveryTests: XCTestCase {
    private let kernelError = ShellResult(
        exitCode: 1, stdout: "",
        stderr: "Error: default kernel not configured for architecture arm64, please use `container system kernel set`")

    func testInstallsTheRecommendedKernelAndRetriesOnce() async throws {
        let shell = FakeShell()
        // 1st call: scratch start fails for want of a kernel; then the kernel
        // install and every later call succeed.
        shell.responses = [kernelError]
        let options = LinuxImageOptions(
            image: "ubuntu:24.04", target: "out", storedTokens: [.github])
        let target = try await ContainerImagePreparer(shell: shell).prepare(
            options, versions: .init(github: "1", gitea: "1"))
        XCTAssertEqual(target, "out")
        let calls = shell.calls
        XCTAssertTrue(
            calls.contains { $0.suffix(4) == ["system", "kernel", "set", "--recommended"] },
            "expected a kernel install, got \(calls)")
        XCTAssertEqual(calls.filter { $0.contains("run") && $0.contains("--detach") }.count, 2, "start retried once")
    }

    func testOtherStartFailuresAreNotRetried() async {
        let shell = FakeShell()
        shell.responses = [ShellResult(exitCode: 1, stdout: "", stderr: "Error: 401 Unauthorized")]
        let options = LinuxImageOptions(
            image: "nope", target: "out", storedTokens: [.github])
        do {
            _ = try await ContainerImagePreparer(shell: shell).prepare(
                options, versions: .init(github: "1", gitea: "1"))
            XCTFail("expected a failure")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("401 Unauthorized"), error.localizedDescription)
        }
        XCTAssertFalse(shell.calls.contains { $0.contains("kernel") })
    }
}
