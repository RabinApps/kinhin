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
