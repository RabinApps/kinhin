import XCTest

@testable import KinhinKit

/// Contract for `ContainerFakingShell` as a `ShellRunning`: the cases the
/// container lifecycle tests rely on must read like the real `Shell` driving
/// the real `container` CLI — stdin scripts are delivered (the protocol
/// default refuses them), the `container` verbs shape state exactly like the
/// CLI (`list` prints one name per line, `run --name` creates, `delete`
/// removes) so the real `LinuxContainerCLI` driver composes a full
/// provision → exec → teardown cycle against it, and every argv is recorded
/// for assertions. No container tooling is installed or launched.
final class ContainerFakingShellContractTests: XCTestCase {
    /// A conformer on the protocol's default stdin implementation: it refuses.
    /// The real `Shell` and `ContainerFakingShell` both override it — that
    /// override is what these tests pin.
    private struct StdinlessShell: ShellRunning, Sendable {
        func run(_ argv: [String], cwd: URL?, timeout: TimeInterval) async throws -> ShellResult {
            ShellResult(exitCode: 0, stdout: "", stderr: "")
        }
    }

    private func makeRoute() -> RepoRoute {
        RepoRoute(repo: "acme/widgets", image: "kinhin-ci-linux", ephemeral: true, bootTimeout: 30)
    }

    // MARK: - stdin delivery

    func testStdinScriptsAreDeliveredLikeTheRealShellInsteadOfRefused() async throws {
        // Real Shell: the script reaches the child's stdin and comes back on
        // stdout — the exec analogue of SSH, secrets kept out of argv.
        let real = try await Shell().run(["/bin/cat"], input: Data("guest script".utf8), cwd: nil, timeout: 10)
        XCTAssertTrue(real.succeeded)
        XCTAssertEqual(real.stdout, "guest script")

        // The protocol's default refuses stdin; the fake must not.
        do {
            _ = try await StdinlessShell().run(["x"], input: Data(), cwd: nil, timeout: 1)
            XCTFail("the default must refuse stdin, or the override would go untested")
        } catch ShellError.launchFailed {
            // expected
        }

        let fake = ContainerFakingShell()
        let result = try await fake.run(
            ["/usr/local/bin/container", "exec", "-i", "kinhin-1", "/bin/bash", "-ls"],
            input: Data("register me".utf8), cwd: nil, timeout: 30)
        XCTAssertTrue(result.succeeded, "exec succeeds like a container CLI that ran the script")
        let recorded = try XCTUnwrap(fake.argvSnapshot().last)
        XCTAssertEqual(
            Array(recorded.suffix(2)), ["<stdin>", "register me"],
            "the script stays inspectable, the way FakeShell records it")
    }

    // MARK: - CLI state model

    func testTheRealContainerDriverCompletesItsLifecycleAgainstTheFake() async throws {
        let shell = ContainerFakingShell()
        let runtime = AppleContainerRuntime(
            shell: shell, binPath: "/usr/local/bin/container", exists: { _ in true })

        try await runtime.provision(id: "kinhin-1", route: makeRoute())
        let running = try await runtime.existingInstanceIDs()
        XCTAssertEqual(
            running, ["kinhin-1"],
            "`container list --all --quiet` must print the name the run created, one per line")

        let result = try await runtime.execRegistration("kinhin-1", ip: nil, "register", timeout: 60)
        XCTAssertTrue(result.succeeded, "the exec transport reports the script's exit status like the real CLI")
        let execArgv = try XCTUnwrap(shell.argvSnapshot().first { $0.contains("exec") })
        XCTAssertTrue(execArgv.contains("/bin/bash"))
        XCTAssertTrue(execArgv.contains("<stdin>"), "the registration script travels on stdin, out of argv")

        try await runtime.teardown(id: "kinhin-1")
        let after = try await runtime.existingInstanceIDs()
        XCTAssertEqual(after, [], "`container delete --force` must take the container out of the next list")
    }

    // MARK: - Recording

    func testEveryInvocationIsRecordedAndForeignCommandsNeverMutateState() async throws {
        let shell = ContainerFakingShell()
        let foreign = try await shell.run(["/usr/bin/true"], cwd: nil, timeout: 5)
        XCTAssertTrue(foreign.succeeded, "commands the fake does not model still answer success")
        let run = try await shell.run(
            ["/usr/local/bin/container", "run", "--detach", "--name", "kinhin-2", "image"],
            cwd: nil, timeout: 5)
        XCTAssertTrue(run.succeeded)

        XCTAssertEqual(shell.argvSnapshot().count, 2, "tests assert on argvSnapshot(), in order")
        XCTAssertEqual(shell.argvSnapshot().first, ["/usr/bin/true"])

        let listed = try await shell.run(
            ["/usr/local/bin/container", "list", "--all", "--quiet"], cwd: nil, timeout: 5)
        XCTAssertEqual(listed.stdout, "kinhin-2", "only container invocations shape the fake's state")
    }
}
