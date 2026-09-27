import XCTest

@testable import KinhinKit
@testable import KinhinTestSupport

final class ShellTests: XCTestCase {
    func testShellCapturesStdout() async throws {
        let result = try await Shell().run(["/bin/echo", "kinhin-test-123"], cwd: nil, timeout: 10)
        XCTAssertTrue(result.succeeded)
        XCTAssertTrue(result.stdout.contains("kinhin-test-123"))
    }

    func testShellCapturesStderrAndExitCode() async throws {
        let result = try await Shell().run(["/bin/sh", "-c", "echo oops >&2; exit 3"], cwd: nil, timeout: 10)
        XCTAssertEqual(result.exitCode, 3)
        XCTAssertFalse(result.succeeded)
        XCTAssertTrue(result.stderr.contains("oops"))
    }

    func testShellTimeoutReturns124() async throws {
        let result = try await Shell().run(["/bin/sleep", "5"], cwd: nil, timeout: 0.5)
        XCTAssertEqual(result.exitCode, 124, "watchdog must mark timed-out processes")
    }

    /// Cancelling the surrounding task terminates the still-running child and
    /// throws CancellationError promptly — the caller never waits out the
    /// child's own timeout. This is what lets a detached engine lifecycle
    /// exit at once instead of sitting out a registration script.
    func testShellCancellationTerminatesRunningChild() async throws {
        let clock = ContinuousClock()
        let started = Date()
        let elapsed = try await clock.measure {
            do {
                // Child would run 60s; its own timeout is even longer.
                let task = Task {
                    try await Shell().run(["/bin/sleep", "60"], cwd: nil, timeout: 120)
                }
                // Wait until the child is actually running so the cancel
                // lands on a live process, not a not-yet-launched one.
                try await Task.sleep(for: .milliseconds(300))
                task.cancel()
                _ = try await task.value
                XCTFail("expected CancellationError")
            } catch is CancellationError {
                // expected
            }
        }
        XCTAssertLessThan(elapsed, .seconds(10), "cancellation must terminate the child, not wait it out")
        XCTAssertLessThan(Date().timeIntervalSince(started), 10)
    }

    /// Pin the not-cancelled path: the command finishing normally (even well
    /// before any timeout) keeps its exit code — cancellation handling must
    /// not turn late completions into CancellationError.
    func testShellNormalCompletionUnaffectedByCancellationHandler() async throws {
        let result = try await Shell().run(["/bin/sh", "-c", "sleep 0.3; echo done"], cwd: nil, timeout: 30)
        XCTAssertTrue(result.succeeded)
        XCTAssertTrue(result.stdout.contains("done"))
    }

    func testShellLaunchFailureThrows() async {
        do {
            _ = try await Shell().run(["/nonexistent/binary-xyz"], cwd: nil, timeout: 5)
            XCTFail("expected launch failure")
        } catch let error as ShellError {
            guard case .launchFailed = error else { return XCTFail("wrong error") }
        } catch {
            XCTFail("wrong error type: \(error)")
        }
    }
}
