import XCTest

@testable import KinhinKit
@testable import KinhinTestSupport

final class SSHExecutorTests: XCTestCase {
    func testSSHArgvCarriesBase64ScriptAndTarget() async throws {
        let shell = FakeShell()
        let ssh = SSHExecutor(shell: shell, user: "admin")
        let script = "echo hello && uname -m"
        _ = try await ssh.exec(vm: "kinhin-x", user: "admin", ip: "192.168.64.5", script: script, timeout: 60)

        let argv = try XCTUnwrap(shell.calls.first)
        XCTAssertEqual(argv.first, "ssh")
        XCTAssertTrue(argv.contains("-o"), "ssh hardening options must be present")
        XCTAssertTrue(argv.contains("StrictHostKeyChecking=no"))
        XCTAssertTrue(argv.contains("BatchMode=yes"))
        // Target is user@ip as the second-to-last element; the remote command is last.
        XCTAssertEqual(argv[argv.count - 2], "admin@192.168.64.5")
        let remote = try XCTUnwrap(argv.last)
        XCTAssertTrue(remote.contains("| base64 --decode | bash -s"))
        // The embedded base64 payload must decode back to the exact script.
        let parts = remote.split(separator: " ")
        let b64 = try XCTUnwrap(parts.dropFirst().first)
        let decoded = String(decoding: try XCTUnwrap(Data(base64Encoded: String(b64))), as: UTF8.self)
        XCTAssertEqual(decoded, script)
    }
}
