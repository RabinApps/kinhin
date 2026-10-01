import XCTest

@testable import KinhinKit
@testable import KinhinTestSupport

final class SSHExecutorTests: XCTestCase {
    func testScriptTravelsOverStdinNotTheCommandLine() async throws {
        let shell = FakeShell()
        let ssh = SSHExecutor(shell: shell, user: "admin")
        let script = "echo hello && uname -m # token=s3cr3t"
        _ = try await ssh.exec(vm: "kinhin-x", user: "admin", ip: "192.168.64.5", script: script, timeout: 60)

        let argv = try XCTUnwrap(shell.calls.first)
        XCTAssertEqual(argv.first, "ssh")
        XCTAssertTrue(argv.contains("StrictHostKeyChecking=no"))
        XCTAssertTrue(argv.contains("BatchMode=yes"))
        // FakeShell appends the delivered stdin as a trailing "<stdin>", text pair.
        XCTAssertEqual(Array(argv.suffix(4)), ["admin@192.168.64.5", "bash -s", "<stdin>", script])
        // The real command line carries neither the script nor an encoding of it.
        let commandLine = argv.dropLast(2).joined(separator: " ")
        XCTAssertFalse(commandLine.contains("s3cr3t"))
        XCTAssertFalse(commandLine.contains("base64"))
    }
}
