import Synchronization
import XCTest

@testable import KinhinKit
@testable import KinhinTestSupport

/// Behavior of the shared error-handling helpers and the paths that stopped
/// swallowing failures.
final class ErrorHandlingTests: XCTestCase {
    private struct Boom: Error, LocalizedError {
        var errorDescription: String? { "boom" }
    }

    // MARK: - bestEffort

    func testBestEffortSwallowsButLogsFailure() async {
        let marker = "best-effort-\(UUID().uuidString)"
        await bestEffortAsync("test", marker) { throw Boom() }
        XCTAssertTrue(Log.snapshot(limit: 50).contains { $0.message.contains(marker) && $0.message.contains("boom") })
    }

    func testBestEffortDoesNotLogCancellation() async {
        let marker = "cancelled-\(UUID().uuidString)"
        await bestEffortAsync("test", marker) { throw CancellationError() }
        XCTAssertFalse(Log.snapshot(limit: 50).contains { $0.message.contains(marker) })
    }

    // MARK: - withTransientRetry

    func testRetryRecoversFromTransientFailure() async throws {
        var calls = 0
        let value = try await withTransientRetry(baseDelay: 0.001, isTransient: { _ in true }) {
            calls += 1
            if calls < 3 { throw Boom() }
            return "ok"
        }
        XCTAssertEqual(value, "ok")
        XCTAssertEqual(calls, 3)
    }

    func testRetryGivesUpAndRethrowsLastError() async {
        var calls = 0
        do {
            _ = try await withTransientRetry(retries: 2, baseDelay: 0.001, isTransient: { _ in true }) {
                calls += 1
                throw Boom()
            }
            XCTFail("expected a throw")
        } catch {
            XCTAssertTrue(error is Boom)
        }
        XCTAssertEqual(calls, 3, "one attempt plus two retries")
    }

    func testRetrySkipsNonTransientErrors() async {
        var calls = 0
        do {
            _ = try await withTransientRetry(baseDelay: 0.001, isTransient: { _ in false }) {
                calls += 1
                throw Boom()
            }
            XCTFail("expected a throw")
        } catch {}
        XCTAssertEqual(calls, 1)
    }

    func testForgeTransientClassification() {
        XCTAssertTrue(ForgeTransport.isTransient(ForgeAPIError.http(forge: .gitea, code: 503, body: "")))
        XCTAssertTrue(ForgeTransport.isTransient(ForgeAPIError.nonHTTPResponse(forge: .gitea)))
        XCTAssertTrue(ForgeTransport.isTransient(URLError(.timedOut)))
        XCTAssertFalse(ForgeTransport.isTransient(ForgeAPIError.http(forge: .gitea, code: 400, body: "")))
        XCTAssertFalse(ForgeTransport.isTransient(ForgeAPIError.unauthorized(forge: .gitea)))
        XCTAssertFalse(ForgeTransport.isTransient(ForgeAPIError.notFound(forge: .gitea, what: "x")))
    }

    // MARK: - Tart runtime

    func testTartProvisionSurfacesListFailureInsteadOfCloningBlind() async {
        let tart = FakeTart()
        tart.failList = true
        let runtime = TartRuntime(tart: tart, bootTimeout: { 300 })
        do {
            try await runtime.provision(
                id: "vm-1", route: RepoRoute(repo: "acme/widgets", image: "base", ephemeral: true, bootTimeout: 300))
            XCTFail("a failed VM listing must not be treated as an empty list")
        } catch {
            XCTAssertTrue(error is TartError)
        }
        XCTAssertTrue(tart.cloneCalls.isEmpty)
    }

    /// Softnet VMs briefly answer "Host is down" (no ARP reply yet) while booting.
    func testTartRegistrationRetriesHostIsDown() async throws {
        let ssh = FlakySSH(failures: 2, stderr: "ssh: connect to host 10.0.0.2 port 22: Host is down")
        let runtime = TartRuntime(
            tart: FakeTart(), bootTimeout: { 300 }, ssh: ssh, sshReadyWindow: 30, sshRetryInterval: .milliseconds(1))
        let result = try await runtime.execRegistration("vm-1", ip: "10.0.0.2", "true", timeout: 5)
        XCTAssertTrue(result.succeeded)
        XCTAssertEqual(ssh.calls, 3)
    }

    /// `tart ip` answers before sshd listens: registration retries the
    /// "nothing listening yet" errors, but not a genuine script failure.
    func testTartRegistrationRetriesUntilSSHListens() async throws {
        let ssh = FlakySSH(failures: 2, stderr: "ssh: connect to host 10.0.0.2 port 22: Operation timed out")
        let runtime = TartRuntime(
            tart: FakeTart(), bootTimeout: { 300 }, ssh: ssh, sshReadyWindow: 30, sshRetryInterval: .milliseconds(1))
        let result = try await runtime.execRegistration("vm-1", ip: "10.0.0.2", "true", timeout: 5)
        XCTAssertTrue(result.succeeded)
        XCTAssertEqual(ssh.calls, 3)

        let broken = FlakySSH(failures: 5, stderr: "bash: config.sh: command failed")
        let runtime2 = TartRuntime(
            tart: FakeTart(), bootTimeout: { 300 }, ssh: broken, sshReadyWindow: 30,
            sshRetryInterval: .milliseconds(1))
        let failed = try await runtime2.execRegistration("vm-1", ip: "10.0.0.2", "true", timeout: 5)
        XCTAssertFalse(failed.succeeded)
        XCTAssertEqual(broken.calls, 1, "a real failure is not retried")
    }

    /// No ssh process is spawned until the port answers: the cheap probe
    /// absorbs the boot window.
    func testRegistrationDoesNotSpawnSSHUntilThePortIsOpen() async throws {
        let ssh = PortGatedSSH(closedProbes: 4)
        let runtime = TartRuntime(
            tart: FakeTart(), bootTimeout: { 300 }, ssh: ssh, sshReadyWindow: 30, sshRetryInterval: .milliseconds(1),
            sshProbeInterval: .milliseconds(1))
        let result = try await runtime.execRegistration("vm-1", ip: "10.0.0.2", "true", timeout: 5)
        XCTAssertTrue(result.succeeded)
        XCTAssertEqual(ssh.probes, 5)
        XCTAssertEqual(ssh.execs, 1, "ssh ran once, after the port opened")
    }

    func testRegistrationTriesSSHOnceTheWindowRunsOutEvenIfThePortStaysClosed() async throws {
        let ssh = PortGatedSSH(closedProbes: .max)
        let runtime = TartRuntime(
            tart: FakeTart(), bootTimeout: { 300 }, ssh: ssh, sshReadyWindow: 0.05,
            sshRetryInterval: .milliseconds(1), sshProbeInterval: .milliseconds(5))
        let result = try await runtime.execRegistration("vm-1", ip: "10.0.0.2", "true", timeout: 5)
        XCTAssertTrue(result.succeeded)
        XCTAssertEqual(ssh.execs, 1, "one real attempt reports the error when the window is gone")
    }

    func testTartTeardownDoesNotNeedList() async throws {
        let tart = FakeTart()
        tart.vms["vm-1"] = TartVM(name: "vm-1", source: "base", status: "running")
        tart.failList = true
        let runtime = TartRuntime(tart: tart, bootTimeout: { 300 })
        try await runtime.teardown(id: "vm-1")
        XCTAssertEqual(tart.deleteCalls, ["vm-1"])
    }

    /// A failed listing must not read as "no VMs" (recovery would drop
    /// every record and orphan the running VMs).
    func testTartExistingInstanceIDsThrowsWhenListFails() async {
        let tart = FakeTart()
        tart.failList = true
        do {
            _ = try await TartRuntime(tart: tart, bootTimeout: { 300 }).existingInstanceIDs()
            XCTFail("a failed tart list must throw")
        } catch {}
    }

    // MARK: - Config edit errors

    func testConfigEditErrorMessages() {
        XCTAssertEqual(ConfigEditError.notFound("/x").errorDescription, "config not found at /x")
        XCTAssertEqual(ConfigEditError.validation("bad").errorDescription, "bad")
        XCTAssertTrue(ConfigEditError.rejected("bad").errorDescription?.hasPrefix("config validation failed") == true)
    }

    // MARK: - Paths

    func testSupportDirectoriesResolveWithoutTrapping() {
        XCTAssertEqual(Paths.appSupport.lastPathComponent, "Kinhin")
        XCTAssertTrue(Paths.legacyAppSupport.path.hasSuffix("/Orchard"))
        XCTAssertTrue(Daemon.agentPlistPath().path.contains("LaunchAgents"))
    }
}

private final class FlakySSH: SSHExecuting, Sendable {
    private let state = Mutex(0)
    let failures: Int
    let stderr: String
    init(failures: Int, stderr: String) {
        self.failures = failures
        self.stderr = stderr
    }
    var calls: Int { state.withLock { $0 } }
    func exec(vm: String, user: String, ip: String, script: String, timeout: TimeInterval) async throws -> ShellResult {
        let n = state.withLock { n -> Int in
            n += 1
            return n
        }
        if n <= failures { return ShellResult(exitCode: 255, stdout: "", stderr: stderr) }
        return ShellResult(exitCode: 0, stdout: "ok", stderr: "")
    }

    func allowKeys(_ key: String) async throws {
        // No-op: the real SSH executor ignores this call too.
    }
}

private final class PortGatedSSH: SSHExecuting, Sendable {
    private let state = Mutex((probes: 0, execs: 0))
    let closedProbes: Int
    init(closedProbes: Int) { self.closedProbes = closedProbes }
    var probes: Int { state.withLock { $0.probes } }
    var execs: Int { state.withLock { $0.execs } }

    func isSSHPortOpen(ip: String) async -> Bool {
        state.withLock { state in
            state.probes += 1
            return state.probes > closedProbes
        }
    }

    func exec(vm: String, user: String, ip: String, script: String, timeout: TimeInterval) async throws -> ShellResult {
        state.withLock { $0.execs += 1 }
        return ShellResult(exitCode: 0, stdout: "ok", stderr: "")
    }

    func allowKeys(_ key: String) async throws {}
}
