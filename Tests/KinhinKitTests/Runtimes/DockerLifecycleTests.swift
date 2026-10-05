import Foundation
import Synchronization
import XCTest

@testable import KinhinKit
@testable import KinhinTestSupport

/// The Docker/Linux runtime path through the full engine lifecycle —
/// `provision → awaitReady → registrationScript → execRegistration → teardown`
/// — driven through a scripted container/docker double that models real CLI
/// state (so `docker ps` sees a `run --name X` container and recovery/idempotency
/// behave like the real daemon). Mirrors the Tart path's
/// provision→register→teardown cycle and the Apple `container` engine test's
/// assertion shape.
///
/// These are the Docker analogues of the fleet tests that cover Tart clone→boot
/// →SSH register→delete, and of `AppleContainerRuntimeTests
/// .testEngineWithContainerConfigRunsContainerLifecycle` — but for the Docker
/// runtime seam, with the real Linux agent scripts and real forge token plumbing.
final class DockerLifecycleTests: XCTestCase {
    // MARK: - Happy path: provision → boot → register → ready

    func testHappyPathRunsTheProvisionThenRegisterCycle() async throws {
        let shell = DockerLifecycleTests_DockerFakingShell()
        var config = makeTestConfig()
        config.docker = .init(image: "ghcr.io/acme/kinhin-ci-linux", cpus: 2, memoryGB: 4)
        let github = FakeGitHub()
        github.queueDepth = 1
        let ssh = FakeSSH()
        let engine = makeEngine(config: config, github: github, shell: shell, ssh: ssh)

        try await engine.reconcileOnce()
        try await waitUntil(timeout: 10) {
            await engine.status().records.first?.phase == .ready
        }

        let status = await engine.status()
        let record = try XCTUnwrap(status.records.first)
        XCTAssertEqual(record.runtime, RuntimeID.docker.rawValue)
        XCTAssertEqual(
            status.runtime, RuntimeID.docker.rawValue,
            "docker is the primary runtime when only docker: is configured"
        )
        XCTAssertNil(record.ip, "docker records carry no IP — there is no SSH transport")
        XCTAssertTrue(ssh.scripts.isEmpty, "SSH transport must be unused")

        let argvs = shell.argvSnapshot()
        XCTAssertTrue(
            argvs.contains { $0.contains("run") && $0.contains("--name") && $0.contains("ghcr.io/acme/kinhin-ci-linux") },
            "provision must docker run the configured image: \(argvs)"
        )
        XCTAssertTrue(
            argvs.contains { $0.contains("exec") && $0.contains("/bin/bash") },
            "registration must run over docker exec: \(argvs)"
        )

        let execCall = try XCTUnwrap(argvs.first { $0.contains("exec") && $0.contains("/bin/bash") })
        let stdinIndex = try XCTUnwrap(execCall.firstIndex(of: "<stdin>"))
        let deliveredScript = execCall[stdinIndex + 1]
        XCTAssertTrue(
            deliveredScript.contains("/opt/actions-runner"),
            "exec'd script is the Linux GitHub agent path: \(deliveredScript)"
        )
        XCTAssertTrue(
            deliveredScript.contains("config.sh --url"),
            "exec'd script registers the runner: \(deliveredScript)"
        )
        XCTAssertTrue(
            deliveredScript.contains("--token 'RT-1'"),
            "exec'd script carries the minted token: \(deliveredScript)"
        )
        let deliveredName = "--name 'kinhin-\(record.id)'"
        XCTAssertTrue(
            deliveredScript.contains("--name 'kinhin-") && deliveredScript.contains(deliveredName),
            "exec'd script names the runner: \(deliveredScript)"
        )
    }

    // MARK: - Recovery / idempotency through the engine

    func testExistingContainerIsStartedNotReRun() async throws {
        let shell = DockerLifecycleTests_DockerFakingShell()
        shell.seedContainer(named: "kinhin-recover")
        var config = makeTestConfig()
        config.docker = .init(image: "ghcr.io/acme/kinhin-ci-linux", cpus: 2, memoryGB: 4)
        let github = FakeGitHub()
        github.queueDepth = 1
        let ssh = FakeSSH()
        let engine = makeEngine(config: config, github: github, shell: shell, ssh: ssh)

        try await engine.reconcileOnce()
        try await waitUntil(timeout: 10) {
            await engine.status().records.first?.phase == .ready
        }

        let argvs = shell.argvSnapshot()
        // Recovery path: the existing container is found by name in `docker ps`
        // and started, never re-created with `run --detach`.
        XCTAssertTrue(
            argvs.contains { $0.contains("start") && $0.contains("kinhin-recover") },
            "existing container is started, not re-run: \(argvs)"
        )
        XCTAssertFalse(
            argvs.contains { $0.contains("run") && $0.contains("--name") && $0.contains("kinhin-recover") },
            "no second container is created for the existing id: \(argvs)"
        )
    }

    func testRecoveryReusesAStrayContainerAndRegistersIt() async throws {
        let shell = DockerLifecycleTests_DockerFakingShell()
        var config = makeTestConfig()
        config.docker = .init(image: "ghcr.io/acme/kinhhin-ci-linux", cpus: 2, memoryGB: 4)
        let github = FakeGitHub()
        github.queueDepth = 1
        let ssh = FakeSSH()
        let engine = makeEngine(config: config, github: github, shell: shell, ssh: ssh)

        // Seed after engine creation so the first reconcile sees the stray.
        shell.seedContainer(named: "kinhin-stray")

        // No queued work yet — the stray container is recovered but no new
        // record is spawned. Then queue a job so the engine adopts it.
        try await engine.reconcileOnce()
        let before = await engine.status()
        // The stray container should have been adopted (recovery).
        let adopted = before.records.first { $0.id == "kinhin-stray" }
        XCTAssertNotNil(
            adopted,
            "a surviving container is adopted by recovery: \(before.records.map { "\($0.id)=\($0.phase)" })"
        )

        // Now queue work so the adopted record proceeds to register.
        github.queueDepth = 1
        try await waitUntil(timeout: 10) {
            let s = await engine.status()
            return s.records.first(where: { $0.id == "kinhin-stray" })?.phase == .ready
        }

        let status = await engine.status()
        let record = try XCTUnwrap(status.records.first(where: { $0.id == "kinhin-stray" }))
        XCTAssertEqual(record.runtime, RuntimeID.docker.rawValue)
        let argvs = shell.argvSnapshot()
        XCTAssertTrue(
            argvs.contains { $0.contains("exec") && $0.contains("/bin/bash") },
            "adopted container is still registered over exec: \(argvs)"
        )
    }

    // MARK: - Slow boot
    // MARK: - Slow boot: awaitReady polls until the container appears

    func testAwaitReadyPollsUntilTheContainerAppears() async throws {
        let shell = DockerLifecycleTests_DockerFakingShell()
        shell.psResponses = [
            "",                    // not yet
            "other-container\n",   // still not ours
            "kinhin-slow\n"        // up
        ]
        var config = makeTestConfig()
        config.docker = .init(image: "ghcr.io/acme/kinhin-ci-linux", cpus: 2, memoryGB: 4)
        let github = FakeGitHub()
        github.queueDepth = 1
        let ssh = FakeSSH()
        let engine = makeEngine(config: config, github: github, shell: shell, ssh: ssh)

        try await engine.reconcileOnce()
        try await waitUntil(timeout: 10) {
            await engine.status().records.first?.phase == .ready
        }

        let argvs = shell.argvSnapshot()
        let lists = argvs.filter { $0.contains("ps") || $0.contains("list") }
        let psAListCount = lists.filter { $0.contains("ps") && $0.contains("--all") && $0.contains("--format") }.count
        XCTAssertEqual(
            psAListCount, 3,
            "awaitReady polls ps -a exactly three times (initial id check + two poll attempts): \(argvs)"
        )
        let execArgv = try XCTUnwrap(argvs.first { $0.contains("exec") && $0.contains("kinhin-slow") })
        let stdinIndex = try XCTUnwrap(execArgv.firstIndex(of: "<stdin>"))
        let execScript = execArgv[stdinIndex + 1]
        XCTAssertTrue(
            execScript.contains("kinhin-slow"),
            "registration runs after the container is visible: \(execScript)"
        )
}

    func testBootWatchPollsDockerListUntilRunning() async throws {
        let shell = DockerLifecycleTests_DockerFakingShell()
        // Provision creates the container; awaitRunning polls `docker ps -a`
        // until the name appears.
        shell.psResponses = [
            "",              // not running yet
            "other\n",       // still not ours
            "kinhin-poll\n"  // ours
        ]
        var config = makeTestConfig()
        config.docker = .init(image: "ghcr.io/acme/kinhin-ci-linux", cpus: 2, memoryGB: 4)
        let github = FakeGitHub()
        github.queueDepth = 1
        let ssh = FakeSSH()
        let engine = makeEngine(config: config, github: github, shell: shell, ssh: ssh)

        try await engine.reconcileOnce()
        let statusBefore = await engine.status()
        let targetID = try XCTUnwrap(statusBefore.records.first?.id)
        try await waitUntil(timeout: 10) {
            let s = await engine.status()
            return s.records.first(where: { $0.id == targetID })?.phase == .ready
        }

        let argvs = shell.argvSnapshot()
        // One `docker ps` for the idempotency check, one `docker run`, then
        // the `docker ps -a` polls inside awaitRunning.
        let listCalls = argvs.filter { $0.contains("ps") || $0.contains("list") }
        XCTAssertGreaterThanOrEqual(
            listCalls.count, 3,
            "provision + awaitRunning list polling: \(argvs)"
        )
    }

    // MARK: - Teardown on ephemeral job completion

    func testEphemeralJobCompletesAndTearsTheContainerDown() async throws {
        let shell = DockerLifecycleTests_DockerFakingShell()
        var config = makeTestConfig()
        config.docker = .init(image: "ghcr.io/acme/kinhin-ci-linux", cpus: 2, memoryGB: 4)
        config.vm.ephemeral = true
        let github = FakeGitHub()
        github.queueDepth = 1
        let ssh = FakeSSH()
        let engine = makeEngine(config: config, github: github, shell: shell, ssh: ssh)

        try await engine.reconcileOnce()
        try await waitUntil(timeout: 10) {
            await engine.status().records.first?.phase == .ready
        }

        let status = await engine.status()
        let id = try XCTUnwrap(status.records.first?.id)
        // Simulate the runner picking up a job, then deregistering (ephemeral).
        github.register(name: id, busy: true)
        try await waitUntil(timeout: 10) {
            await engine.status().records.first(where: { $0.id == id })?.phase == .busy
        }
        github.deregister(name: id)
        try await waitUntil(timeout: 10) {
            await engine.status().records.first(where: { $0.id == id }) == nil
        }

        let argvs = shell.argvSnapshot()
        XCTAssertTrue(
            argvs.contains { $0.contains("rm") && $0.contains("--force") && $0.contains(id) },
            "finished ephemeral container is removed: \(argvs)"
        )
        XCTAssertTrue(shell.containers.isEmpty, "no containers left in the fake's state")
    }

    func testMultiRunnerContainerStaysUntilEveryRunnerDeregisters() async throws {
        let shell = DockerLifecycleTests_DockerFakingShell()
        var config = makeTestConfig()
        config.docker = .init(image: "ghcr.io/acme/kinhin-ci-linux", cpus: 2, memoryGB: 4)
        config.runnersPerVM = 2
        config.vm.ephemeral = true
        let github = FakeGitHub()
        github.queueDepth = 1
        let ssh = FakeSSH()
        let engine = makeEngine(config: config, github: github, shell: shell, ssh: ssh)

        try await engine.reconcileOnce()
        try await waitUntil(timeout: 10) {
            await engine.status().records.filter { $0.phase == .ready }.count == 1
        }
        let statusForId = await engine.status()
        let id = try XCTUnwrap(statusForId.records.first?.id)

        // Deliver two runners.
        github.register(name: "\(id)-r1", busy: false)
        github.register(name: "\(id)-r2", busy: false)
        try await waitUntil(timeout: 10) {
            let s = await engine.status()
            return s.records.first(where: { $0.id == id })?.phase == .ready
        }

        // r1 finishes and deregisters; the container must stay (r2 still needs it).
        github.deregister(name: "\(id)-r1")
        try await waitUntil(timeout: 10) {
            let s = await engine.status()
            return s.records.first(where: { $0.id == id })?.phase == .ready
        }
        let stillAlive = await engine.status().records.first(where: { $0.id == id })
        XCTAssertNotNil(stillAlive, "container survives partial deregistration")
        XCTAssertEqual(stillAlive?.phase, VMPhase.ready, "r2 still idle-registered")

        // Second runner deregisters → container removed.
        github.deregister(name: "\(id)-r2")
        try await waitUntil(timeout: 10) {
            await engine.status().records.first(where: { $0.id == id }) == nil
        }

        let argvs = shell.argvSnapshot()
        XCTAssertTrue(
            argvs.contains { $0.contains("rm") && $0.contains("--force") && $0.contains(id) },
            "container removed only after both runners deregistered: \(argvs)"
        )
        XCTAssertTrue(shell.containers.isEmpty)
    }

    func testMultiRunnerRegistrationScriptContainsBothIndexedRunners() async throws {
        let shell = DockerLifecycleTests_DockerFakingShell()
        var config = makeTestConfig()
        config.docker = .init(image: "ghcr.io/acme/kinhin-ci-linux", cpus: 2, memoryGB: 4)
        config.runnersPerVM = 2
        let github = FakeGitHub()
        github.queueDepth = 1
        let ssh = FakeSSH()
        let engine = makeEngine(config: config, github: github, shell: shell, ssh: ssh)

        try await engine.reconcileOnce()
        try await waitUntil(timeout: 10) {
            await engine.status().records.first?.phase == .ready
        }
        let status = await engine.status()
        let record = try XCTUnwrap(status.records.first)
        let id = record.id

        let argvs = shell.argvSnapshot()
        let execCall = try XCTUnwrap(argvs.first { $0.contains("exec") && $0.contains("/bin/bash") })
        let stdinIndex = try XCTUnwrap(execCall.firstIndex(of: "<stdin>"))
        let script = execCall[stdinIndex + 1]

        XCTAssertTrue(script.contains("/opt/actions-runner"), "runner 1 dir: \(script)")
        XCTAssertTrue(script.contains("/opt/actions-runner-2"), "runner 2 dir: \(script)")
        XCTAssertTrue(script.contains("--name '\(id)-r1'"), "runner 1 name: \(script)")
        XCTAssertTrue(script.contains("--name '\(id)-r2'"), "runner 2 name: \(script)")
        XCTAssertTrue(script.contains("nohup ./run.sh > run-1.log"), "runner 1 start: \(script)")
        XCTAssertTrue(
            script.contains("nohup ./run.sh > run-2.log"),
            "runner 2 start: \(script)"
        )
    }

    // MARK: - Failed registration → failed record + teardown

    func testFailedRegistrationMarksTheRecordFailedAndTearsDown() async throws {
        let shell = DockerLifecycleTests_DockerFakingShell()
        shell.execResults = [
            ShellResult(exitCode: 1, stdout: "", stderr: "config.sh: timeout registering runner")
        ]
        var config = makeTestConfig()
        config.docker = .init(image: "ghcr.io/acme/kinhin-ci-linux", cpus: 2, memoryGB: 4)
        let github = FakeGitHub()
        github.queueDepth = 1
        let ssh = FakeSSH()
        let engine = makeEngine(config: config, github: github, shell: shell, ssh: ssh)

        try await engine.reconcileOnce()
        try await waitUntil(timeout: 10) {
            await engine.status().records.first?.phase == .failed
        }

        let status = await engine.status()
        let record = try XCTUnwrap(status.records.first)
        XCTAssertEqual(record.phase, .failed)
        let reported = record.error?.contains("timeout registering runner") ?? false
            || record.error?.contains("config.sh") ?? false
        XCTAssertTrue(
            reported,
            "the script stderr is reported: \(record.error ?? "nil")"
        )

        // Teardown must still run on the failed instance.
        let argvs = shell.argvSnapshot()
        XCTAssertTrue(
            argvs.contains { $0.contains("rm") && $0.contains("--force") && $0.contains(record.id) },
            "failed instance is still torn down: \(argvs)"
        )
        XCTAssertTrue(shell.containers.isEmpty, "no containers left in the fake's state")

        // Give the engine a pass with no demand so it stops trying to replace it.
        github.queueDepth = 0
        try await engine.reconcileOnce()
        try await waitUntil(timeout: 10) {
            await engine.status().records.isEmpty
        }
    }

    func testRegistrationScriptFailureDoesNotLeaveAStrayContainer() async throws {
        let shell = DockerLifecycleTests_DockerFakingShell()
        shell.execResults = [
            ShellResult(exitCode: 1, stdout: "", stderr: "runner registration failed: 403 Forbidden")
        ]
        var config = makeTestConfig()
        config.docker = .init(image: "ghcr.io/acme/kinhin-ci-linux", cpus: 2, memoryGB: 4)
        let github = FakeGitHub()
        github.queueDepth = 1
        let ssh = FakeSSH()
        let engine = makeEngine(config: config, github: github, shell: shell, ssh: ssh)

        try await engine.reconcileOnce()
        // Wait for the failed lifecycle to run teardown.
        try await waitUntil(timeout: 10) {
            await engine.status().records.first?.phase == .failed
        }
        // Give the engine another pass at draining the failed record.
        try await engine.reconcileOnce()
        let status = await engine.status()
        // The failed record is still expected to exist momentarily; the key
        // teardown contract here is the argv shape, not the exact record timing.
        let argvs = shell.argvSnapshot()
        XCTAssertTrue(
            argvs.contains { $0.contains("run") && $0.contains("--name") },
            "provision still happened: \(argvs)"
        )
        XCTAssertTrue(
            argvs.contains { $0.contains("rm") && $0.contains("--force") },
            "teardown still ran: \(argvs)"
        )
    }

    // MARK: - Engine-level routing
    // MARK: - Engine-level routing stays on Tart when Docker is absent

    func testEngineWithoutDockerConfigKeepsTartLifecycle() async throws {
        let github = FakeGitHub()
        github.queueDepth = 1
        let tart = FakeTart()
        let ssh = FakeSSH()
        let shell = DockerLifecycleTests_DockerFakingShell()
        let engine = makeEngine(config: makeTestConfig(), github: github, tart: tart, shell: shell, ssh: ssh)

        try await engine.reconcileOnce()
        try await waitUntil(timeout: 10) {
            await engine.status().records.first?.phase == .ready
        }
        let status = await engine.status()
        XCTAssertEqual(status.runtime, RuntimeID.tart.rawValue)
        XCTAssertEqual(status.records.first?.runtime, RuntimeID.tart.rawValue)
        XCTAssertNotNil(status.records.first?.ip, "tart records carry the VM IP")
        XCTAssertTrue(!ssh.scripts.isEmpty, "tart lifecycle registers over SSH")
        XCTAssertEqual(tart.cloneCalls.count, 1)
    }

    // MARK: - Helpers

    private func makeEngine(
        config: KinhinConfig,
        github: FakeGitHub,
        tart: TartControlling = FakeTart(),
        shell: DockerLifecycleTests_DockerFakingShell,
        ssh: SSHExecuting
    ) -> FleetEngine {
        FleetEngine(
            config: config,
            github: github,
            tart: tart,
            store: makeTestStore(),
            ssh: ssh,
            host: testHost,
            containerShell: shell,
            dependencies: .init(tokenLoader: { _, _ in "test-token" }, lifecycleDrainTimeout: .seconds(15))
        )
    }
}

// MARK: - Scripted docker double

/// A shell double that models `docker ps/run/start/rm` as real state: `run
/// --name X` creates container X, `start X` ensures it is present, `rm
/// --force X` removes it, and `ps`/`ps -a` return the current names — so
/// provision, awaitRunning, and recovery behave like the real CLI. Other
/// argvs (including `exec`) return success and record the delivered script on
/// stdin so tests can inspect the registration script the runtime shipped.
///
/// Queued `ps`/`ps -a` responses let a test model a slow start without a
/// private state machine; queued `exec` results let a test force a registration
/// failure.
///
/// Mirrors the double in `DockerToolchainCacheTests`; a third consumer would
/// justify extracting it to `KinhinTestSupport`, but a local double is
/// preferred while it is private to one test file.
private final class DockerLifecycleTests_DockerFakingShell: ShellRunning, Sendable {
    private struct State: Sendable {
        var argvs: [[String]] = []
        var containers: Set<String> = []

        var psResponses: [String] = []
        var execResults: [ShellResult] = []

        mutating func handle(_ argv: [String]) -> ShellResult {
            argvs.append(argv)
            guard argv.first?.hasSuffix("/docker") == true || argv.first == "docker" else {
                return ShellResult(exitCode: 0, stdout: "", stderr: "")
            }
            let verb = argv.dropFirst().first
            switch verb {
            case "ps":
                if let head = psResponses.first {
                    psResponses.removeFirst()
                    if !head.isEmpty {
                        return ShellResult(exitCode: 0, stdout: head, stderr: "")
                    }
                }
                return ShellResult(
                    exitCode: 0,
                    stdout: containers.sorted().joined(separator: "\n"),
                    stderr: "")
            case "run":
                if let nameIndex = argv.firstIndex(of: "--name"), argv.indices.contains(nameIndex + 1) {
                    containers.insert(argv[nameIndex + 1])
                }
                return ShellResult(exitCode: 0, stdout: "", stderr: "")
            case "start":
                if let name = argv.last { containers.insert(name) }
                return ShellResult(exitCode: 0, stdout: "", stderr: "")
            case "rm":
                if let name = argv.last { containers.remove(name) }
                return ShellResult(exitCode: 0, stdout: "", stderr: "")
            default:
                return ShellResult(exitCode: 0, stdout: "", stderr: "")
            }
        }

        mutating func handleExec(_ argv: [String], stdin: String) -> ShellResult {
            argvs.append(argv + ["<stdin>", stdin])
            guard argv.first?.hasSuffix("/docker") == true || argv.first == "docker" else {
                return ShellResult(exitCode: 0, stdout: "", stderr: "")
            }
            if argv.dropFirst().first == "exec", let head = execResults.first {
                execResults.removeFirst()
                return head
            }
            return ShellResult(exitCode: 0, stdout: "", stderr: "")
        }
    }

    private let state = Mutex(State())

    func seedContainer(named name: String) {
        _ = state.withLock { $0.containers.insert(name) }
    }

    var psResponses: [String] {
        get { state.withLock { $0.psResponses } }
        set { state.withLock { $0.psResponses = newValue } }
    }

    var execResults: [ShellResult] {
        get { state.withLock { $0.execResults } }
        set { state.withLock { $0.execResults = newValue } }
    }
    var containers: Set<String> {
        state.withLock { $0.containers }
    }

    func run(_ argv: [String], cwd: URL?, timeout: TimeInterval) async throws -> ShellResult {
        state.withLock { $0.handle(argv) }
    }

    func run(_ argv: [String], input: Data, cwd: URL?, timeout: TimeInterval) async throws -> ShellResult {
        let stdin = String(decoding: input, as: UTF8.self)
        let cleanArgv = argv.last == "<stdin>" ? Array(argv.dropLast(2)) : argv
        return state.withLock { $0.handleExec(cleanArgv, stdin: stdin) }
    }

    func argvSnapshot() -> [[String]] {
        state.withLock { $0.argvs }
    }
}
