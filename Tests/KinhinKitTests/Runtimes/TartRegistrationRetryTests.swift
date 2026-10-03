import XCTest

@testable import KinhinKit
@testable import KinhinTestSupport

/// The registration bring-up window: sshd can lag the DHCP lease by minutes on
/// a big image's first boot, so retries continue for at least `vm_boot_timeout`
/// (the config key documents "seconds a freshly booted VM has to register"),
/// and give-up afterward with the SSH error surfaced.
final class TartRegistrationRetryTests: XCTestCase {
    private static let timeoutStderr = "ssh: connect to host 192.168.165.238 port 22: Operation timed out"

    private func makeRuntime(bootTimeout: Int, sshReadyWindow: TimeInterval, ssh: FakeSSH) -> TartRuntime {
        TartRuntime(
            tart: FakeTart(), bootTimeout: { bootTimeout }, ssh: ssh,
            sshReadyWindow: sshReadyWindow, sshRetryInterval: .milliseconds(20),
            sshProbeInterval: .milliseconds(10))
    }

    /// An sshd that starts answering late still registers: the retry window
    /// never ends before vm_boot_timeout has passed, even when the runtime's
    /// own floor is smaller.
    func testRegistrationRetriesUntilAtLeastTheBootTimeout() async throws {
        let ssh = FakeSSH()
        // sshd answers late: failing until 0.5s is past the runtime's own
        // 0.2s floor (the pre-fix whole window) yet well inside the 2s
        // vm_boot_timeout — only the boot-timeout floor saves this run.
        ssh.failWith = Self.timeoutStderr  // retryable: "not listening yet"
        ssh.failUntil = Date().addingTimeInterval(0.5)
        let runtime = makeRuntime(bootTimeout: 2, sshReadyWindow: 0.2, ssh: ssh)

        let result = try await runtime.execRegistration("vm", ip: "192.168.64.9", "echo hi", timeout: 60)

        XCTAssertTrue(result.succeeded, "registration should land once sshd answers: \(result.stderr)")
        XCTAssertGreaterThanOrEqual(
            ssh.scripts.count, 2, "the late sshd was retried within the boot-timeout window")
    }

    /// A guest that never opens port 22 fails registration once the window is
    /// out — the engine then deletes the VM and scales a fresh one.
    func testRegistrationGivesUpAfterTheWindowAndSurfacesTheSSHError() async throws {
        let ssh = FakeSSH()
        ssh.failWith = Self.timeoutStderr
        let runtime = makeRuntime(bootTimeout: 1, sshReadyWindow: 0.2, ssh: ssh)

        let result = try await runtime.execRegistration("vm", ip: "192.168.64.9", "echo hi", timeout: 60)

        XCTAssertFalse(result.succeeded)
        XCTAssertTrue(result.stderr.contains("Operation timed out"), result.stderr)
        XCTAssertGreaterThan(ssh.scripts.count, 1, "the exec was retried while the window lasted")
    }
}
