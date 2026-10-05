import Synchronization
import XCTest

@testable import KinhinKit
@testable import KinhinTestSupport

/// Contract for `FakeSSH` as an `SSHExecuting`: the cases the fleet and bake
/// tests branch on must read exactly like the real `SSHExecutor`'s answers —
/// `succeeded` plus verbatim stderr on failure, stdout passed through, the
/// caller's timeout reaching the shell, `allowKeys` as a no-op, and the
/// protocol's documented network-less defaults (port open, host-key hooks
/// ignored) that keep the engine's readiness poll moving. The real side runs
/// `SSHExecutor` against `FakeShell`; no ssh is ever spawned.
final class FakeSSHContractTests: XCTestCase {
    /// Captures the timeouts the real executor forwards to the shell — no
    /// production shell exposes them, and the bake tests assert on
    /// `FakeSSH.timeouts`, so this test-specific double pins the pass-through.
    private final class TimeoutCapturingShell: ShellRunning, Sendable {
        private let box = Mutex<[TimeInterval]>([])
        var timeouts: [TimeInterval] { box.withLock { $0 } }

        func run(_ argv: [String], cwd: URL?, timeout: TimeInterval) async throws -> ShellResult {
            box.withLock { $0.append(timeout) }
            return ShellResult(exitCode: 0, stdout: "", stderr: "")
        }

        func run(_ argv: [String], input: Data, cwd: URL?, timeout: TimeInterval) async throws -> ShellResult {
            box.withLock { $0.append(timeout) }
            return ShellResult(exitCode: 0, stdout: "", stderr: "")
        }
    }

    private func exec(
        _ ssh: SSHExecuting, script: String, timeout: TimeInterval = 60
    ) async throws -> ShellResult {
        try await ssh.exec(vm: "vm-1", user: "admin", ip: "10.0.0.2", script: script, timeout: timeout)
    }

    // MARK: - Result shape

    func testSuccessAndStdoutPassThroughLikeTheRealExecutor() async throws {
        let realShell = FakeShell()
        realShell.defaultResult = ShellResult(exitCode: 0, stdout: "Darwin", stderr: "")
        let real = SSHExecutor(shell: realShell, user: "admin")
        let fake = FakeSSH()
        fake.setStdout("Darwin", forCall: 0)

        let realResult = try await exec(real, script: "uname -s")
        let fakeResult = try await exec(fake, script: "uname -s")

        XCTAssertTrue(realResult.succeeded)
        XCTAssertTrue(fakeResult.succeeded, "a guest that answered exits 0 on both sides")
        XCTAssertEqual(fakeResult.stdout, realResult.stdout, "stdout passes through untouched on both sides")
    }

    func testFailureSurfacesStderrWithANonZeroExitLikeSSHDoes() async throws {
        let realShell = FakeShell()
        realShell.failAll = "Permission denied (publickey)"
        let real = SSHExecutor(shell: realShell, user: "admin")
        let fake = FakeSSH()
        fake.failWith = "Permission denied (publickey)"

        let realResult = try await exec(real, script: "true")
        let fakeResult = try await exec(fake, script: "true")

        XCTAssertFalse(realResult.succeeded)
        XCTAssertFalse(fakeResult.succeeded, "the engine branches on succeeded")
        XCTAssertNotEqual(fakeResult.exitCode, 0)
        XCTAssertEqual(fakeResult.stderr, realResult.stderr, "stderr passes through verbatim on both sides")
    }

    func testGuestProbeAnswerParsesLikeARealDarwinGuest() async throws {
        // The real executor relays whatever the guest prints for `uname -s`;
        // the fake's default answers exactly like the curated macOS images.
        let realShell = FakeShell()
        realShell.defaultResult = ShellResult(exitCode: 0, stdout: "Linux", stderr: "")
        let real = SSHExecutor(shell: realShell, user: "admin")
        let fake = FakeSSH()

        let realResult = try await exec(real, script: GuestOS.probeScript)
        let fakeResult = try await exec(fake, script: GuestOS.probeScript)

        XCTAssertEqual(
            GuestOS.parse(unameOutput: realResult.stdout), .linux,
            "the real executor relays the guest's answer unchanged")
        XCTAssertEqual(
            GuestOS.parse(unameOutput: fakeResult.stdout), .macOS,
            "the fake's default probe answer is the macOS image's own")
    }

    func testTheCallersTimeoutReachesTheShellUnchanged() async throws {
        let realShell = TimeoutCapturingShell()
        let real = SSHExecutor(shell: realShell, user: "admin")
        let fake = FakeSSH()

        _ = try await exec(real, script: "true", timeout: 1234)
        _ = try await exec(fake, script: "true", timeout: 1234)

        XCTAssertEqual(realShell.timeouts, [1234], "the real executor forwards the caller's timeout verbatim")
        XCTAssertEqual(fake.timeouts, [1234], "the fake records the same value the bake asserts on")
    }

    // MARK: - No-ops and protocol defaults

    func testAllowKeysIsANoOpLikeTheRealExecutor() async throws {
        let realShell = FakeShell()
        let real = SSHExecutor(shell: realShell, user: "admin")
        let fake = FakeSSH()

        try await real.allowKeys("ssh-ed25519 AAAA")
        try await fake.allowKeys("ssh-ed25519 AAAA")

        XCTAssertTrue(realShell.calls.isEmpty, "the real executor deliberately does nothing here")
        XCTAssertTrue(fake.scripts.isEmpty, "the fake records no script either")
    }

    func testHostKeyAndPortHooksFollowTheProtocolDefaultsForNetworklessExecutors() async throws {
        let fake = FakeSSH()
        let portOpen = await fake.isSSHPortOpen(ip: "10.0.0.2")
        XCTAssertTrue(portOpen, "the engine's readiness poll must pass without a real sshd")

        try await fake.pinHostKey(vm: "vm-1", publicKey: "ssh-ed25519 AAAA")
        await fake.forgetHostKey(vm: "vm-1")
        await fake.noteHostKeyUnpinned(vm: "vm-1", reason: "unreachable")
        XCTAssertTrue(fake.scripts.isEmpty, "the hooks never reach exec")
    }
}
