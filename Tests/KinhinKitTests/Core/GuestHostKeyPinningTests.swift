import Synchronization
import XCTest

@testable import KinhinKit
@testable import KinhinTestSupport

/// Records pin / forget / unpinned notes instead of touching ssh or the disk.
private final class PinSpy: SSHExecuting, Sendable {
    private let state = Mutex((pinned: [String: String](), forgotten: [String](), unpinned: [String: String]()))
    var pinned: [String: String] { state.withLock { $0.pinned } }
    var forgotten: [String] { state.withLock { $0.forgotten } }
    var unpinned: [String: String] { state.withLock { $0.unpinned } }

    func exec(vm: String, user: String, ip: String, script: String, timeout: TimeInterval) async throws -> ShellResult {
        ShellResult(exitCode: 0, stdout: "", stderr: "")
    }
    func allowKeys(_ key: String) async throws {}
    func pinHostKey(vm: String, publicKey: String) async throws { state.withLock { $0.pinned[vm] = publicKey } }
    func forgetHostKey(vm: String) async { state.withLock { $0.forgotten.append(vm) } }
    func noteHostKeyUnpinned(vm: String, reason: String) async { state.withLock { $0.unpinned[vm] = reason } }
}

final class GuestHostKeyPinningTests: XCTestCase {
    private let key = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIAbCdEfGhIjKlMnOpQrStUvWxYz0123456789abcdefgh"

    private func tempDirectory() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("kinhin-pin-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }  // test cleanup
        return dir
    }

    private func executor(_ shell: FakeShell, _ dir: URL) -> SSHExecutor {
        SSHExecutor(
            shell: shell, user: "admin", knownHostsDirectory: dir.appendingPathComponent("hosts"),
            fallbackMarker: dir.appendingPathComponent("marker"))
    }

    // MARK: - Parsing and the guest script

    func testParseHostKeyTakesTheEd25519LineAndDropsTheComment() {
        XCTAssertEqual(GuestHostKeyPinning.parseHostKey("\(key) root@guest\n"), key)
        XCTAssertEqual(GuestHostKeyPinning.parseHostKey("noise\n\(key)\n"), key)
        XCTAssertNil(GuestHostKeyPinning.parseHostKey(""))
        XCTAssertNil(GuestHostKeyPinning.parseHostKey("ssh-rsa AAAAB3Nza root@guest"))
        XCTAssertNil(GuestHostKeyPinning.parseHostKey("ssh-ed25519 AAAA\"; rm -rf / #"))
    }

    func testTheRotateScriptReplacesEveryHostKeyAndPrintsTheEd25519One() {
        let script = GuestHostKeyPinning.rotateScript
        let removed = script.range(of: "rm -f /etc/ssh/ssh_host_*_key")?.lowerBound
        let generated = script.range(of: "ssh-keygen -A")?.lowerBound
        let printed = script.range(of: "cat /etc/ssh/ssh_host_ed25519_key.pub")?.lowerBound
        XCTAssertNotNil(removed)
        XCTAssertTrue(try XCTUnwrap(removed) < XCTUnwrap(generated))
        XCTAssertTrue(try XCTUnwrap(generated) < XCTUnwrap(printed))
        XCTAssertTrue(script.contains("systemctl restart ssh"), "a Linux sshd service must reload its keys")
    }

    func testTartControllerRunsTheRotationAndHardeningThroughTheGuestAgent() async throws {
        let shell = FakeShell()
        shell.defaultResult = ShellResult(exitCode: 0, stdout: "\(key) root@guest\n", stderr: "")
        let tart = try TartController(configuredPath: "/usr/bin/true", shell: shell)
        let returned = try await tart.rotateGuestHostKey(vm: "kinhin-1")
        XCTAssertEqual(returned, key)
        try await tart.hardenGuestSSH(vm: "kinhin-1")

        let calls = shell.calls
        XCTAssertEqual(Array(calls[0].prefix(4)), ["/usr/bin/true", "exec", "kinhin-1", "bash"])
        XCTAssertEqual(calls[0].last, GuestHostKeyPinning.rotateScript)
        XCTAssertEqual(calls[1].last, RunnerBootstrap.sshHardeningScript())
    }

    func testTartControllerRejectsAnAnswerWithoutAHostKey() async throws {
        let shell = FakeShell()
        shell.defaultResult = ShellResult(exitCode: 0, stdout: "garbage", stderr: "")
        let tart = try TartController(configuredPath: "/usr/bin/true", shell: shell)
        do {
            _ = try await tart.rotateGuestHostKey(vm: "kinhin-1")
            XCTFail("a missing key must not read as success")
        } catch {}
    }

    // MARK: - SSHExecutor

    func testAPinnedInstanceIsConnectedToWithStrictCheckingAgainstItsOwnKnownHostsFile() async throws {
        let dir = try tempDirectory()
        let shell = FakeShell()
        let ssh = executor(shell, dir)
        try await ssh.pinHostKey(vm: "kinhin-7", publicKey: key)
        _ = try await ssh.exec(vm: "kinhin-7", user: "admin", ip: "192.168.64.7", script: "true", timeout: 5)

        let argv = try XCTUnwrap(shell.calls.first)
        let file = dir.appendingPathComponent("hosts/kinhin-7.known_hosts")
        XCTAssertTrue(argv.contains("StrictHostKeyChecking=yes"))
        XCTAssertTrue(argv.contains("HostKeyAlias=kinhin-7"))
        XCTAssertTrue(argv.contains("UserKnownHostsFile=\(file.path)"))
        XCTAssertFalse(argv.contains("StrictHostKeyChecking=no"))
        XCTAssertFalse(argv.contains("UserKnownHostsFile=/dev/null"))
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "kinhin-7 \(key)\n")
        let mode = try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? Int
        XCTAssertEqual(mode, 0o600)
        let dirMode =
            try FileManager.default.attributesOfItem(atPath: file.deletingLastPathComponent().path)[
                .posixPermissions] as? Int
        XCTAssertEqual(dirMode, 0o700)
    }

    func testAnUnpinnedInstanceKeepsTheOldBehaviourAndAPinDoesNotLeakToOtherInstances() async throws {
        let dir = try tempDirectory()
        let shell = FakeShell()
        let ssh = executor(shell, dir)
        try await ssh.pinHostKey(vm: "kinhin-1", publicKey: key)
        _ = try await ssh.exec(vm: "kinhin-2", user: "admin", ip: "192.168.64.9", script: "true", timeout: 5)
        let argv = try XCTUnwrap(shell.calls.first)
        XCTAssertTrue(argv.contains("StrictHostKeyChecking=no"))
        XCTAssertTrue(argv.contains("UserKnownHostsFile=/dev/null"))
    }

    func testForgettingAnInstanceDeletesItsKnownHostsFile() async throws {
        let dir = try tempDirectory()
        let ssh = executor(FakeShell(), dir)
        try await ssh.pinHostKey(vm: "kinhin-1", publicKey: key)
        let file = dir.appendingPathComponent("hosts/kinhin-1.known_hosts")
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path))
        await ssh.forgetHostKey(vm: "kinhin-1")
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
    }

    func testMalformedKeysAndUnsafeIDsAreNotPinned() async throws {
        let ssh = executor(FakeShell(), try tempDirectory())
        for bad in ["ssh-rsa AAAAB3Nza", "ssh-ed25519 not$base64", ""] {
            do {
                try await ssh.pinHostKey(vm: "kinhin-1", publicKey: bad)
                XCTFail("pinned '\(bad)'")
            } catch {}
        }
        do {
            try await ssh.pinHostKey(vm: "../escape", publicKey: key)
            XCTFail("pinned an id that is a path")
        } catch {}
    }

    func testAnUnpinnedConnectionIsRecordedForDoctorAndAPinClearsIt() async throws {
        let dir = try tempDirectory()
        let ssh = executor(FakeShell(), dir)
        let marker = dir.appendingPathComponent("marker")
        await ssh.noteHostKeyUnpinned(vm: "kinhin-1", reason: "the guest agent did not answer")
        XCTAssertEqual(
            GuestHostKeyPinning.recordedFallback(marker: marker), "kinhin-1: the guest agent did not answer")
        try await ssh.pinHostKey(vm: "kinhin-2", publicKey: key)
        XCTAssertNil(GuestHostKeyPinning.recordedFallback(marker: marker))
    }

    func testDoctorWarnsWhenTheHostKeyCouldNotBePinned() throws {
        let section = try XCTUnwrap(
            DoctorReportBuilder.securitySection(
                config: makeTestConfig(), softnetInstalled: true, hostKeyUnpinned: "kinhin-1: no agent"))
        XCTAssertEqual(section.hostKeyUnpinned, "kinhin-1: no agent")
        XCTAssertTrue(section.warnings.contains { $0.contains("host key could not be pinned") })
        XCTAssertTrue(section.ok, "an advisory never blocks readiness")
        let clean = try XCTUnwrap(DoctorReportBuilder.securitySection(config: makeTestConfig(), softnetInstalled: true))
        XCTAssertNil(clean.hostKeyUnpinned)
    }

    // MARK: - TartRuntime wiring

    func testAwaitReadyPinsTheKeyTheGuestAgentReturnedAndTeardownForgetsIt() async throws {
        let tart = FakeTart()
        tart.hostKey = key
        let ssh = PinSpy()
        let runtime = TartRuntime(tart: tart, bootTimeout: { 30 }, ssh: ssh)
        _ = try await runtime.awaitReady(id: "kinhin-1", timeout: 5)
        XCTAssertEqual(ssh.pinned["kinhin-1"], key)
        XCTAssertEqual(tart.rotateCalls, ["kinhin-1"])
        try await runtime.teardown(id: "kinhin-1")
        XCTAssertEqual(ssh.forgotten, ["kinhin-1"])
    }

    func testWithoutAgentSupportTheRuntimeFallsBackAndSaysSo() async throws {
        let ssh = PinSpy()
        let runtime = TartRuntime(tart: FakeTart(), bootTimeout: { 30 }, ssh: ssh)
        let ip = try await runtime.awaitReady(id: "kinhin-1", timeout: 5)
        XCTAssertNotNil(ip, "an unverifiable host key never blocks the boot")
        XCTAssertTrue(ssh.pinned.isEmpty)
        XCTAssertNotNil(ssh.unpinned["kinhin-1"])
    }

    func testAnAgentThatNeverAnswersFallsBackAfterTheWindow() async throws {
        let tart = FakeTart()
        tart.failNext("rotate", stderr: "agent not running")
        let ssh = PinSpy()
        let runtime = TartRuntime(
            tart: tart, bootTimeout: { 30 }, ssh: ssh, hostKeyWindow: 0.05, hostKeyInterval: .milliseconds(10))
        _ = try await runtime.awaitReady(id: "kinhin-1", timeout: 5)
        XCTAssertGreaterThanOrEqual(tart.rotateCalls.count, 2, "retries while the agent comes up")
        XCTAssertTrue(ssh.unpinned["kinhin-1", default: ""].contains("agent not running"))
    }

    // MARK: - Image bake ordering

    /// Snapshots the tart event log at each SSH exec, to prove what ran before it.
    private final class OrderSSH: SSHExecuting, Sendable {
        let tart: FakeTart
        private let seen = Mutex<[[String]]>([])
        init(tart: FakeTart) { self.tart = tart }
        var eventsAtEachExec: [[String]] { seen.withLock { $0 } }
        func exec(vm: String, user: String, ip: String, script: String, timeout: TimeInterval) async throws
            -> ShellResult
        {
            seen.withLock { $0.append(tart.events) }
            return ShellResult(exitCode: 0, stdout: script == "uname -s" ? "Darwin" : "ok", stderr: "")
        }
        func allowKeys(_ key: String) async throws {}
    }

    func testTheBakeClosesPasswordLoginThroughTheAgentBeforeAnySSHConnection() async throws {
        let tart = FakeTart()
        tart.hostKey = key
        let ssh = OrderSSH(tart: tart)
        let preparer = ImagePreparer(tart: tart, ssh: ssh)
        try await preparer.run(
            ImagePreparer.Options(
                hasGitHubToken: true, hasGiteaToken: false, hasGitLabToken: false, hasBuildkiteToken: false,
                hasAzureDevOpsToken: false))
        let scratch = try XCTUnwrap(tart.cloneCalls.first?.name)
        let expected = ["run:\(scratch)", "installKey:\(scratch)", "harden:\(scratch)", "rotate:\(scratch)"]
        let first = try XCTUnwrap(ssh.eventsAtEachExec.first)
        XCTAssertEqual(first, expected, "hardening and host key rotation come before the first SSH exec")
        XCTAssertTrue(ssh.eventsAtEachExec.allSatisfy { $0 == expected })
    }

    func testAFailedAgentHardeningDoesNotFailTheBakeBecauseThePrepareScriptRetriesIt() async throws {
        let tart = FakeTart()
        tart.failNext("harden", stderr: "no agent")
        let ssh = FakeSSH()
        let preparer = ImagePreparer(tart: tart, ssh: ssh)
        try await preparer.run(
            ImagePreparer.Options(
                hasGitHubToken: true, hasGiteaToken: false, hasGitLabToken: false, hasBuildkiteToken: false,
                hasAzureDevOpsToken: false))
        // The verification stays in the SSH-delivered prepare script either way.
        let prepare = try XCTUnwrap(ssh.scripts.first { $0.contains("000-kinhin-hardening.conf") })
        XCTAssertTrue(prepare.contains("\"$SSHD\" -T"))
        XCTAssertTrue(prepare.contains("passwordauthentication no"))
    }

    func testTheBakeSkipsHardeningThroughTheAgentWhenTheAgentTookNoKey() async throws {
        let tart = FakeTart()
        tart.failNext("installKey", stderr: "no agent")
        var preparer = ImagePreparer(tart: tart, ssh: FakeSSH())
        preparer.guestKeyAttempts = 1
        preparer.guestKeyRetryDelay = .zero
        try await preparer.run(
            ImagePreparer.Options(
                hasGitHubToken: true, hasGiteaToken: false, hasGitLabToken: false, hasBuildkiteToken: false,
                hasAzureDevOpsToken: false))
        XCTAssertTrue(tart.hardenCalls.isEmpty)
    }
}
