import XCTest

@testable import KinhinKit

final class ShellInputTests: XCTestCase {
    func testInputReachesTheChildsStdin() async throws {
        let result = try await Shell().run(
            ["/bin/cat"], input: Data("secret script\nline 2\n".utf8), cwd: nil, timeout: 10)
        XCTAssertTrue(result.succeeded)
        XCTAssertEqual(result.stdout, "secret script\nline 2\n")
    }

    func testInputIsNotPartOfTheCommandLine() async throws {
        let result = try await Shell().run(
            ["/bin/sh", "-c", "cat >/dev/null; echo done"], input: Data("token=s3cr3t".utf8), cwd: nil, timeout: 10)
        XCTAssertEqual(result.stdout, "done\n")
    }

    func testBashSReadsAScriptFromStdin() async throws {
        let result = try await Shell().run(
            ["/bin/bash", "-s"], input: Data("echo from-stdin-$((6*7))\n".utf8), cwd: nil, timeout: 10)
        XCTAssertEqual(result.stdout, "from-stdin-42\n")
    }

    func testLargeInputDoesNotDeadlock() async throws {
        let big = Data(repeating: 0x61, count: 1_000_000)  // well past the 64 KB pipe buffer
        let result = try await Shell().run(["/usr/bin/wc", "-c"], input: big, cwd: nil, timeout: 20)
        XCTAssertEqual(result.stdout.trimmingCharacters(in: .whitespacesAndNewlines), "1000000")
    }

    func testChildThatNeverReadsStdinDoesNotCrashUs() async throws {
        let big = Data(repeating: 0x61, count: 1_000_000)
        let result = try await Shell().run(["/usr/bin/true"], input: big, cwd: nil, timeout: 10)
        XCTAssertTrue(result.succeeded)  // reaching this line means no SIGPIPE killed the test process
    }

    func testWithoutInputStdinIsClosed() async throws {
        let result = try await Shell().run(["/bin/cat"], cwd: nil, timeout: 10)
        XCTAssertEqual(result.stdout, "", "no input: the child sees an empty stdin, never ours")
    }

    func testRunnersWithoutStdinSupportRefuseInsteadOfDroppingTheScript() async {
        struct Plain: ShellRunning {
            func run(_ argv: [String], cwd: URL?, timeout: TimeInterval) async throws -> ShellResult {
                ShellResult(exitCode: 0, stdout: "", stderr: "")
            }
        }
        do {
            _ = try await Plain().run(["x"], input: Data("s".utf8), cwd: nil, timeout: 1)
            XCTFail("must throw")
        } catch {
            XCTAssertTrue(error is ShellError)
        }
    }
}
