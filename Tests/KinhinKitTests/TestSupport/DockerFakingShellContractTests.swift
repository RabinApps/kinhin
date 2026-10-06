import XCTest

@testable import KinhinKit
@testable import KinhinTestSupport

/// Contract for the shared `DockerFakingShell` as a `ShellRunning`, in two
/// layers. The state model: the docker verbs it models (`ps`/`run --name`/
/// `start`/`rm` as real state) must be exactly the ones the real
/// `DockerRuntime` (shared `LinuxContainerCLI` driver) issues — the same `ps
/// --format {{.Names}}` enumeration that parses one name per line, `run
/// --detach --name` creating, `rm --force` removing, `exec -i /bin/bash -ls`
/// delivering the registration script on stdin with the argv kept clean —
/// so a full provision → ready → register → teardown cycle completes against
/// the fake, and stdin is delivered the way the real `Shell` delivers it. The
/// scripting hooks: a queued `ps` answer that hides a container for exactly
/// one poll (a slow start), a queued `exec` result that fails exactly once
/// like a real child that exited non-zero (stderr and `failureExcerpt` byte
/// for byte, against the real `Shell`), and `seedContainer` laying down state
/// the recovery path adopts the way it adopts a stray the real CLI reports.
/// No docker tooling is installed or launched.
final class DockerFakingShellContractTests: XCTestCase {
    private let bin = "/usr/local/bin/docker"

    private func makeRoute() -> RepoRoute {
        RepoRoute(repo: "acme/widgets", image: "tahoe-base", ephemeral: true, bootTimeout: 30)
    }

    private func makeRuntime(shell: ShellRunning) -> DockerRuntime {
        DockerRuntime(
            shell: shell, image: "ghcr.io/acme/kinhin-ci-linux", cpus: 2, memoryGB: 4,
            binPath: bin, exists: { _ in true })
    }

    // MARK: - stdin

    func testStdinScriptsReachTheChildLikeTheRealShellAndStayInspectable() async throws {
        // Real Shell: the script reaches the child's stdin and comes back on
        // stdout — the exec analogue of SSH, secrets kept out of argv.
        let real = try await Shell().run(["/bin/cat"], input: Data("register me".utf8), cwd: nil, timeout: 10)
        XCTAssertTrue(real.succeeded)
        XCTAssertEqual(real.stdout, "register me")

        let fake = DockerFakingShell()
        let result = try await fake.run(
            [bin, "exec", "-i", "kinhin-1", "/bin/bash", "-ls"],
            input: Data("register me".utf8), cwd: nil, timeout: 60)
        XCTAssertTrue(result.succeeded, "exec succeeds like a docker CLI that ran the script")
        let recorded = try XCTUnwrap(fake.argvSnapshot().last)
        XCTAssertEqual(
            Array(recorded.suffix(2)), ["<stdin>", "register me"],
            "the script stays inspectable, the way FakeShell records it")
        XCTAssertFalse(
            Array(recorded.dropLast(2)).contains("register me"),
            "the script rides stdin — it must never appear in argv")
    }

    // MARK: - The real driver's lifecycle

    func testTheRealRuntimeCompletesItsLifecycleAgainstTheFake() async throws {
        let shell = DockerFakingShell()
        let runtime = makeRuntime(shell: shell)

        try await runtime.provision(id: "kinhin-1", route: makeRoute())
        let running = try await runtime.existingInstanceIDs()
        XCTAssertEqual(
            running, ["kinhin-1"],
            "`docker ps --all --format {{.Names}}` must print the name run created, one per line")

        let ready = try await runtime.awaitReady(id: "kinhin-1", timeout: 5)
        XCTAssertNil(ready, "the exec transport has no address to dial")

        let result = try await runtime.execRegistration("kinhin-1", ip: nil, "register", timeout: 60)
        XCTAssertTrue(result.succeeded, "the exec transport reports the script's exit status like the real CLI")
        let execArgv = try XCTUnwrap(shell.argvSnapshot().first { $0.contains("exec") })
        XCTAssertEqual(Array(execArgv.prefix(6)), [bin, "exec", "-i", "kinhin-1", "/bin/bash", "-ls"])
        XCTAssertTrue(execArgv.contains("<stdin>"), "the registration script travels on stdin, out of argv")

        await runtime.teardown(id: "kinhin-1")
        let after = try await runtime.existingInstanceIDs()
        XCTAssertEqual(after, [], "`docker rm --force` must take the container out of the next list")
    }

    func testRecoveryStartsTheExistingContainerLikeTheRealCli() async throws {
        let shell = DockerFakingShell()
        let runtime = makeRuntime(shell: shell)

        try await runtime.provision(id: "kinhin-1", route: makeRoute())
        try await runtime.provision(id: "kinhin-1", route: makeRoute())

        let argvs = shell.argvSnapshot()
        let startArgvs = argvs.filter { $0.dropFirst().first == "start" }
        XCTAssertEqual(
            startArgvs.count, 1,
            "a second provision finds the container and issues `docker start`, never a second run: \(argvs)")
        XCTAssertEqual(startArgvs.first?.last, "kinhin-1")
        let containers = try await runtime.existingInstanceIDs()
        XCTAssertEqual(containers, ["kinhin-1"], "the state model stays a single container")
    }

    // MARK: - The argv contract

    func testTheArgvTheRealRuntimeIssuesIsExactlyTheStateTheFakeModels() async throws {
        let shell = DockerFakingShell()
        let runtime = makeRuntime(shell: shell)

        try await runtime.provision(id: "kinhin-1", route: makeRoute())
        _ = try await runtime.awaitReady(id: "kinhin-1", timeout: 5)
        let argvs = shell.argvSnapshot()

        XCTAssertEqual(
            argvs.first { $0.dropFirst().first == "ps" && $0.contains("--all") },
            [bin, "ps", "--all", "--format", "{{.Names}}"],
            "enumeration for recovery lists all containers, names only")
        XCTAssertEqual(
            argvs.first { $0.dropFirst().first == "ps" && !$0.contains("--all") },
            [bin, "ps", "--format", "{{.Names}}"],
            "the readiness poll lists running containers, names only")
        let runArgv = try XCTUnwrap(argvs.first { $0.dropFirst().first == "run" })
        XCTAssertTrue(runArgv.contains("--detach"), "\(runArgv)")
        XCTAssertTrue(
            runArgv.contains("--name") && runArgv.contains("kinhin-1"),
            "the fake's state model keys on --name, which is where the real driver puts the id")

        // The line format the driver parses: the real Shell splitting the
        // same bytes the fake prints reads back the same names.
        let real = try await Shell().run(["/bin/sh", "-c", "printf 'kinhin-1\\nkinhin-2\\n'"], cwd: nil, timeout: 10)
        XCTAssertEqual(real.outputLines, ["kinhin-1", "kinhin-2"])
        _ = try await shell.run(
            [bin, "run", "--detach", "--name", "kinhin-2", "--cpus", "2", "img"], cwd: nil, timeout: 10)
        let ps = try await shell.run([bin, "ps", "--format", "{{.Names}}"], cwd: nil, timeout: 10)
        XCTAssertEqual(ps.outputLines, real.outputLines, "the fake's ps output parses to the same names")

        await runtime.teardown(id: "kinhin-1")
        let finalArgvs = shell.argvSnapshot()
        XCTAssertEqual(
            finalArgvs.first { $0.dropFirst().first == "rm" },
            [bin, "rm", "--force", "kinhin-1"],
            "teardown force-removes by name")
    }

    // MARK: - Queued ps answers

    func testAQueuedPsAnswerHidesAContainerForExactlyOnePoll() async throws {
        let shell = DockerFakingShell()
        let runtime = makeRuntime(shell: shell)
        // The first `ps` (provision's existence check) answers as if only
        // another container existed — our id is "not there yet".
        shell.psResponses = ["kinhin-other"]

        try await runtime.provision(id: "kinhin-1", route: makeRoute())
        let ready = try await runtime.awaitReady(id: "kinhin-1", timeout: 5)
        XCTAssertNil(ready, "the exec transport has no address")

        let listed = try await runtime.existingInstanceIDs()
        XCTAssertEqual(listed, ["kinhin-1"], "the queued override is consumed once; every later ps reads state")
        XCTAssertFalse(listed.contains("kinhin-other"), "the queued answer never became state")
        let psArgvs = shell.argvSnapshot().filter { $0.dropFirst().first == "ps" }
        XCTAssertGreaterThanOrEqual(psArgvs.count, 3, "existence check, readiness poll, enumeration")
        let runArgvs = shell.argvSnapshot().filter { $0.dropFirst().first == "run" }
        XCTAssertEqual(runArgvs.count, 1, "the hidden first ps made provision run exactly one container")
    }

    func testASeededContainerIsAdoptedByRecoveryLikeTheRealCliReportsIt() async throws {
        let shell = DockerFakingShell()
        let runtime = makeRuntime(shell: shell)
        shell.seedContainer(named: "kinhin-stray")

        let existing = try await runtime.existingInstanceIDs()
        XCTAssertEqual(existing, ["kinhin-stray"], "`docker ps --all` reports the stray, one name per line")

        try await runtime.provision(id: "kinhin-stray", route: makeRoute())
        let argvs = shell.argvSnapshot()
        XCTAssertTrue(
            argvs.contains { $0.dropFirst().first == "start" && $0.last == "kinhin-stray" },
            "recovery starts the reported container instead of creating a second one: \(argvs)")
        XCTAssertFalse(argvs.contains { $0.dropFirst().first == "run" }, "no run — the stray already exists")
        let after = try await runtime.existingInstanceIDs()
        XCTAssertEqual(after, ["kinhin-stray"])
    }

    // MARK: - Queued exec results

    func testAQueuedExecFailureReadsLikeARealChildThatExitedNonZero() async throws {
        // Real: a child that printed to stderr and exited 3.
        let real = try await Shell().run(["/bin/sh", "-c", "echo boom >&2; exit 3"], cwd: nil, timeout: 10)
        XCTAssertEqual(real.exitCode, 3)

        let shell = DockerFakingShell()
        let runtime = makeRuntime(shell: shell)
        shell.execResults = [ShellResult(exitCode: 3, stdout: "", stderr: "boom\n")]
        try await runtime.provision(id: "kinhin-1", route: makeRoute())

        let first = try await runtime.execRegistration("kinhin-1", ip: nil, "register", timeout: 60)
        XCTAssertFalse(first.succeeded, "the engine branches on succeeded")
        XCTAssertEqual(first.exitCode, real.exitCode, "the scripted failure carries the same status")
        XCTAssertEqual(first.stderr, real.stderr, "stderr passes through verbatim on both sides")
        XCTAssertEqual(first.failureExcerpt, real.failureExcerpt, "errors show the same excerpt either way")

        let second = try await runtime.execRegistration("kinhin-1", ip: nil, "register", timeout: 60)
        XCTAssertTrue(second.succeeded, "the queue is one answer per exec; the next run starts fresh")

        let execArgv = try XCTUnwrap(shell.argvSnapshot().first { $0.contains("exec") })
        XCTAssertTrue(
            Array(execArgv.suffix(2)).contains("<stdin>"),
            "even a failing exec delivered the script on stdin, out of argv")
    }
}
