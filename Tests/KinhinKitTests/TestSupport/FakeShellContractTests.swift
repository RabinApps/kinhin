import XCTest

@testable import KinhinKit
@testable import KinhinTestSupport

/// Contract for `FakeShell` as a `ShellRunning`: for the cases the engine
/// tests rely on it must answer like the real `Shell` driving a real child —
/// the same success shape (exit 0, stdout through), the same failure shape
/// (non-zero exit, stderr verbatim, the shared `failureExcerpt`), the
/// watchdog's own 124 for a timeout, `ShellError.launchFailed` for a command
/// that cannot start, stdin delivered instead of dropped, and `cwd` as a
/// parameter that never leaks into argv. The real side runs `/bin` tools
/// through the real `Shell`; no network or VM is involved.
final class FakeShellContractTests: XCTestCase {
    /// Asserts `op` fails with `ShellError.launchFailed` — the case callers
    /// treat as "the tool could not be started at all".
    private func assertLaunchFailed(
        _ op: () async throws -> Void, _ message: String,
        file: StaticString = #filePath, line: UInt = #line
    ) async {
        do {
            try await op()
            XCTFail(message, file: file, line: line)
        } catch let error as ShellError {
            guard case .launchFailed = error else {
                return XCTFail("expected ShellError.launchFailed, got \(error)", file: file, line: line)
            }
        } catch {
            XCTFail("expected a ShellError, got \(error)", file: file, line: line)
        }
    }

    // MARK: - Success and failure shape

    func testSuccessReadsLikeARealProcessThatPrintedTheSameThing() async throws {
        let real = try await Shell().run(["/bin/echo", "kinhin-contract"], cwd: nil, timeout: 10)

        let fake = FakeShell()
        fake.defaultResult = ShellResult(exitCode: 0, stdout: real.stdout, stderr: "")
        let answer = try await fake.run(["/bin/echo", "kinhin-contract"], cwd: nil, timeout: 10)

        XCTAssertTrue(real.succeeded)
        XCTAssertTrue(answer.succeeded, "the engine branches on succeeded")
        XCTAssertEqual(answer.exitCode, real.exitCode, "a child that answered exits 0 on both sides")
        XCTAssertEqual(answer.stdout, real.stdout, "stdout passes through untouched on both sides")
        XCTAssertEqual(answer.stderr, real.stderr)
        XCTAssertEqual(fake.calls, [["/bin/echo", "kinhin-contract"]], "every argv is recorded, in order")
    }

    func testAFailingCommandReportsItsCodeAndStderrOnBothSides() async throws {
        let real = try await Shell().run(["/bin/sh", "-c", "echo boom >&2; exit 3"], cwd: nil, timeout: 10)
        let fake = FakeShell()
        fake.failAll = "boom\n"  // the newline the real `echo` prints, byte for byte
        let answer = try await fake.run(["/bin/sh", "-c", "true"], cwd: nil, timeout: 10)

        XCTAssertEqual(real.exitCode, 3)
        XCTAssertFalse(answer.succeeded, "a failing child is never a success, on either side")
        XCTAssertNotEqual(answer.exitCode, 0, "the fake fails with a non-zero status like the real child")
        XCTAssertEqual(answer.stderr, real.stderr, "the failure message passes through verbatim")
        XCTAssertEqual(answer.failureExcerpt, real.failureExcerpt, "errors show the same excerpt either way")
    }

    func testOnlyTheMatchingCommandFailsLikeARealRunWhereOneCommandBroke() async throws {
        let realFailing = try await Shell().run(["/bin/sh", "-c", "exit 3"], cwd: nil, timeout: 10)
        let realPassing = try await Shell().run(["/bin/echo", "fine"], cwd: nil, timeout: 10)
        XCTAssertFalse(realFailing.succeeded)
        XCTAssertTrue(realPassing.succeeded)

        let fake = FakeShell()
        fake.failOn = "exit 3"
        let fakeFailing = try await fake.run(["/bin/sh", "-c", "exit 3"], cwd: nil, timeout: 10)
        let fakePassing = try await fake.run(["/bin/echo", "fine"], cwd: nil, timeout: 10)

        XCTAssertFalse(fakeFailing.succeeded, "failOn pins the failure to the matching argv")
        XCTAssertTrue(fakePassing.succeeded, "the next command is unaffected, like a fresh child")
    }

    // MARK: - stdin

    func testStdinScriptsReachTheChildAndAreRecordedByTheFake() async throws {
        let script = "register me"
        let real = try await Shell().run(["/bin/cat"], input: Data(script.utf8), cwd: nil, timeout: 10)

        let fake = FakeShell()
        fake.defaultResult = ShellResult(exitCode: 0, stdout: script, stderr: "")
        let answer = try await fake.run(["/bin/cat"], input: Data(script.utf8), cwd: nil, timeout: 10)

        XCTAssertEqual(real.stdout, script, "the real child echoes exactly the bytes it was fed")
        XCTAssertTrue(answer.succeeded)
        XCTAssertEqual(answer.stdout, script)
        XCTAssertEqual(
            fake.calls.last, ["/bin/cat", "<stdin>", script],
            "the fake records the script next to the argv, so tests can assert on both")
    }

    // MARK: - Launch failures

    func testLaunchFailuresShareTheErrorCaseTheEngineCatches() async {
        // Real: the executable does not exist.
        await assertLaunchFailed(
            { _ = try await Shell().run(["/nonexistent/kinhin-contract"], cwd: nil, timeout: 5) },
            "a missing binary must never read as an empty success")

        // Fake, both hooks: the same case, so a caller's catch works either way.
        let fake = FakeShell()
        fake.throwOnRun = true
        await assertLaunchFailed(
            { _ = try await fake.run(["/bin/echo", "x"], cwd: nil, timeout: 5) },
            "throwOnRun must fail loudly like an unlaunchable command")

        let scripted = FakeShell()
        scripted.scriptedResponses = [
            ScriptedResponse(whenContainsThrowing: "tart", reason: "no tart binary")
        ]
        await assertLaunchFailed(
            { _ = try await scripted.run(["/usr/local/bin/tart", "list"], cwd: nil, timeout: 5) },
            "a script that answers with a throw fails the same way")
    }

    // MARK: - Timeouts

    func testTimeoutsReadAsExit124AndClassifyTheSameWay() async throws {
        let real = try await Shell().run(["/bin/sleep", "5"], cwd: nil, timeout: 0.5)
        XCTAssertEqual(real.exitCode, 124, "the real watchdog marks a timed-out child 124")

        let fake = FakeShell()
        fake.responses = [ShellResult(exitCode: 124, stdout: "", stderr: "")]
        let answer = try await fake.run(["/bin/sleep", "5"], cwd: nil, timeout: 0.5)

        XCTAssertEqual(answer.exitCode, real.exitCode, "tests script the watchdog's own exit code")
        XCTAssertFalse(answer.succeeded)
        XCTAssertEqual(
            TartHealthProbe.classifyFailure(answer), TartHealthProbe.classifyFailure(real),
            "the engine's failure classification reads both the same")
        XCTAssertEqual(TartHealthProbe.classifyFailure(real), "timed out")
    }

    // MARK: - Working directory

    func testWorkingDirectoryReachesTheChildButNeverTheArgv() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("kinhin-shell-contract-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        // Best-effort cleanup of the test's own temp directory: a leftover
        // empty dir in tmp is harmless, and failing the test here wouldn't be.
        defer { try? FileManager.default.removeItem(at: dir) }
        try Data("marker".utf8).write(to: dir.appendingPathComponent("marker.txt"))

        let real = try await Shell().run(["/bin/ls"], cwd: dir, timeout: 10)
        XCTAssertTrue(real.stdout.contains("marker.txt"), "the child ran inside the given directory")

        let fake = FakeShell()
        let answer = try await fake.run(["/bin/ls"], cwd: dir, timeout: 10)
        XCTAssertTrue(answer.succeeded)
        XCTAssertEqual(fake.calls, [["/bin/ls"]], "cwd is a parameter, never an argv element")
    }

    // MARK: - One answer per call

    func testEachRunConsumesExactlyOneAnswerInOrder() async throws {
        let realFirst = try await Shell().run(["/bin/echo", "one"], cwd: nil, timeout: 10)
        let realSecond = try await Shell().run(["/bin/echo", "two"], cwd: nil, timeout: 10)
        XCTAssertNotEqual(realFirst.stdout, realSecond.stdout, "each real run is its own child")

        let fake = FakeShell()
        fake.responses = [
            ShellResult(exitCode: 0, stdout: "one\n", stderr: ""),
            ShellResult(exitCode: 0, stdout: "two\n", stderr: ""),
        ]
        let first = try await fake.run(["/bin/echo", "x"], cwd: nil, timeout: 10)
        let second = try await fake.run(["/bin/echo", "x"], cwd: nil, timeout: 10)
        let third = try await fake.run(["/bin/echo", "x"], cwd: nil, timeout: 10)

        XCTAssertEqual(
            [first.stdout, second.stdout], ["one\n", "two\n"],
            "queued answers are consumed in order, one per run")
        XCTAssertEqual(third.stdout, "", "an emptied queue falls back to the default answer")
        XCTAssertEqual(fake.calls.count, 3, "every run is recorded, whatever it answered")
    }

    func testScriptedAnswersMatchTheirArgvAndFallBackToTheDefault() async throws {
        let fake = FakeShell()
        fake.defaultResult = ShellResult(exitCode: 1, stdout: "", stderr: "unscripted")
        fake.scriptedResponses = [
            ScriptedResponse(
                whenContainsAll: ["list", "--format"],
                ShellResult(exitCode: 0, stdout: "[{}]", stderr: ""))
        ]

        let scripted = try await fake.run(
            ["/usr/local/bin/tart", "list", "--format", "json"], cwd: nil, timeout: 5)
        XCTAssertEqual(scripted.stdout, "[{}]", "needles match substrings of any single argv element")

        let other = try await fake.run(["/usr/local/bin/tart", "clone", "base", "vm"], cwd: nil, timeout: 5)
        XCTAssertEqual(other.stderr, "unscripted", "an argv no script matched falls back to the default")
        XCTAssertEqual(fake.calls.count, 2)
    }
}
