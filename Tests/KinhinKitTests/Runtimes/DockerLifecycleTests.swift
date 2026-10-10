import Foundation
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
        let shell = DockerFakingShell()
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
        XCTAssertEqual(record.runtimeID, .docker)
        XCTAssertEqual(
            status.runtimeID, .docker,
            "docker is the primary runtime when only docker: is configured"
        )
        XCTAssertNil(record.ip, "docker records carry no IP — there is no SSH transport")
        XCTAssertTrue(ssh.scripts.isEmpty, "SSH transport must be unused")

        let argvs = shell.argvSnapshot()
        XCTAssertTrue(
            argvs.contains {
                $0.contains("run") && $0.contains("--name") && $0.contains("ghcr.io/acme/kinhin-ci-linux")
            },
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
        // `record.id` is the full instance name ("kinhin-<ts>-<hex>"), which
        // is also the name the single-runner script registers.
        let deliveredName = "--name '\(record.id)'"
        XCTAssertTrue(
            deliveredScript.contains("--name 'kinhin-") && deliveredScript.contains(deliveredName),
            "exec'd script names the runner: \(deliveredScript)"
        )
    }

    // MARK: - Recovery / idempotency through the engine

    func testExistingContainerIsStartedNotReRun() async throws {
        let shell = DockerFakingShell()
        shell.seedContainer(named: "kinhin-recover")
        var config = makeTestConfig()
        config.docker = .init(image: "ghcr.io/acme/kinhin-ci-linux", cpus: 2, memoryGB: 4)
        let github = FakeGitHub()
        github.queueDepth = 1
        let ssh = FakeSSH()
        let engine = makeEngine(config: config, github: github, shell: shell, ssh: ssh)

        // Recovery (normally run by `start()`) adopts surviving instances;
        // without it the engine would provision a second container.
        await engine.recoverIfNeeded()
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
        let shell = DockerFakingShell()
        var config = makeTestConfig()
        config.docker = .init(image: "ghcr.io/acme/kinhhin-ci-linux", cpus: 2, memoryGB: 4)
        let github = FakeGitHub()
        github.queueDepth = 0
        let ssh = FakeSSH()
        let engine = makeEngine(config: config, github: github, shell: shell, ssh: ssh)

        // Seed after engine creation so recovery sees the stray.
        shell.seedContainer(named: "kinhin-stray")

        // No queued work: recovery adopts the stray container and no new
        // record is spawned for it.
        await engine.recoverIfNeeded()
        let before = await engine.status()
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
        XCTAssertEqual(record.runtimeID, .docker)
        let argvs = shell.argvSnapshot()
        XCTAssertTrue(
            argvs.contains { $0.contains("exec") && $0.contains("/bin/bash") },
            "adopted container is still registered over exec: \(argvs)"
        )
    }

    // MARK: - Slow boot
    // MARK: - Slow boot: awaitReady polls until the container appears

    func testAwaitReadyPollsUntilTheContainerAppears() async throws {
        let shell = DockerFakingShell()
        shell.psResponses = [
            "",  // the provision-time existence check: not created yet
            "other-container\n",  // first poll: still not ours
            // Queue exhausted → the fake lists its real state, which now
            // holds the container `run` just created.
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
        // One existence check (`ps -a`, so a stopped container counts), one
        // `docker run`, then awaitRunning's `docker ps` polls until the
        // container shows up: exactly three listings for this script.
        let psCalls = argvs.filter { $0.contains("ps") }
        XCTAssertEqual(psCalls.count, 3, "existence check + two awaitRunning polls: \(argvs)")
        XCTAssertEqual(
            psCalls.first?.contains("--all"), true,
            "the existence check lists stopped containers too: \(argvs)"
        )
        let readyStatus = await engine.status()
        let record = try XCTUnwrap(readyStatus.records.first)
        let execArgv = try XCTUnwrap(argvs.first { $0.contains("exec") && $0.contains("/bin/bash") })
        let stdinIndex = try XCTUnwrap(execArgv.firstIndex(of: "<stdin>"))
        let execScript = execArgv[stdinIndex + 1]
        XCTAssertTrue(
            execScript.contains(record.id),
            "registration runs against the record's container once it is visible: \(execScript)"
        )
    }

    func testBootWatchPollsDockerListUntilRunning() async throws {
        let shell = DockerFakingShell()
        // Provision creates the container; awaitRunning polls `docker ps -a`
        // until the name appears.
        shell.psResponses = [
            "",  // not running yet
            "other\n",  // still not ours
            "kinhin-poll\n",  // ours
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
        let shell = DockerFakingShell()
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
        let shell = DockerFakingShell()
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

        // Deliver two runners. r1 reports busy while r2 sits idle-registered;
        // waiting for `.busy` also guarantees the exit watch polled the pair
        // (a deregistration the watcher never saw would read as "never
        // registered" and hold the container for the full 120 s deadline).
        github.register(name: "\(id)-r1", busy: true)
        github.register(name: "\(id)-r2", busy: false)
        try await waitUntil(timeout: 10) {
            let s = await engine.status()
            return s.records.first(where: { $0.id == id })?.phase == .busy
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
        let shell = DockerFakingShell()
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
        let shell = DockerFakingShell()
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
        let reported =
            record.error?.contains("timeout registering runner") ?? false
            || record.error?.contains("config.sh") ?? false
        XCTAssertTrue(
            reported,
            "the script stderr is reported: \(record.error ?? "nil")"
        )

        // Teardown runs on the next pass (step 1 drains failed records);
        // with no demand the failed instance is torn down, not replaced.
        github.queueDepth = 0
        try await engine.reconcileOnce()
        try await waitUntil(timeout: 10) {
            await engine.status().records.isEmpty
        }

        let argvs = shell.argvSnapshot()
        XCTAssertTrue(
            argvs.contains { $0.contains("rm") && $0.contains("--force") && $0.contains(record.id) },
            "failed instance is still torn down: \(argvs)"
        )
        XCTAssertTrue(shell.containers.isEmpty, "no containers left in the fake's state")
    }

    func testRegistrationScriptFailureDoesNotLeaveAStrayContainer() async throws {
        let shell = DockerFakingShell()
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
        // The phase flips to failed before the teardown runs, so wait for the
        // removal itself; the contract here is the argv shape, not the timing.
        try await waitUntil(timeout: 10) {
            shell.argvSnapshot().contains { $0.contains("rm") && $0.contains("--force") }
        }
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
        let shell = DockerFakingShell()
        let engine = makeEngine(config: makeTestConfig(), github: github, tart: tart, shell: shell, ssh: ssh)

        try await engine.reconcileOnce()
        try await waitUntil(timeout: 10) {
            await engine.status().records.first?.phase == .ready
        }
        let status = await engine.status()
        XCTAssertEqual(status.runtimeID, .tart)
        XCTAssertEqual(status.records.first?.runtimeID, .tart)
        XCTAssertNotNil(status.records.first?.ip, "tart records carry the VM IP")
        XCTAssertTrue(!ssh.scripts.isEmpty, "tart lifecycle registers over SSH")
        XCTAssertEqual(tart.cloneCalls.count, 1)
    }

    // MARK: - Helpers

    private func makeEngine(
        config: KinhinConfig,
        github: FakeGitHub,
        tart: TartControlling = FakeTart(),
        shell: DockerFakingShell,
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
