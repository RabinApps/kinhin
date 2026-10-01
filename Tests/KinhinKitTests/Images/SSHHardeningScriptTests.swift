import XCTest

@testable import KinhinKit

final class SSHHardeningScriptTests: XCTestCase {
    private var scratch: URL!

    override func setUpWithError() throws {
        scratch = FileManager.default.temporaryDirectory.appendingPathComponent("kn-ssh-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: scratch)
    }

    func testBothGuestsDisablePasswordLoginWhenPrepared() {
        for (label, script) in [
            ("macOS", GuestOS.macOS.prepareScript()), ("linux", GuestOS.linux.prepareScript()),
        ] {
            XCTAssertTrue(script.contains("PasswordAuthentication no"), label)
            XCTAssertTrue(script.contains("KbdInteractiveAuthentication no"), label)
            XCTAssertTrue(script.contains("000-kinhin-hardening.conf"), "\(label): sorts before Apple's 100-macos.conf")
        }
    }

    func testScriptIsValidBash() throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = ["-n", "-c", RunnerBootstrap.sshHardeningScript()]
        try process.run()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0)
    }

    // MARK: - Run against a fake sshd

    /// Runs the script for real with `sudo` as a no-op, `/etc/ssh` redirected
    /// into a scratch directory and an `sshd` stand-in answering `-t`/`-T`.
    private func run(testExit: Int, effective: String) throws -> (status: Int32, stderr: String, conf: String?) {
        let bin = scratch.appendingPathComponent("bin")
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        let sshd = bin.appendingPathComponent("sshd")
        try """
        #!/bin/bash
        case "$1" in
          -t) exit \(testExit) ;;
          -T) echo "\(effective)" ;;
        esac
        """.write(to: sshd, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: sshd.path)

        let dropIns = scratch.appendingPathComponent("sshd_config.d")
        let script = RunnerBootstrap.sshHardeningScript()
            .replacingOccurrences(of: "/etc/ssh/sshd_config.d", with: dropIns.path)
        let wrapper = "sudo() { \"$@\"; }\n" + script

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = ["-c", wrapper]
        process.environment = ["PATH": bin.path + ":/usr/bin:/bin"]
        let err = Pipe()
        process.standardError = err
        try process.run()
        let stderr = String(decoding: err.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        process.waitUntilExit()
        let conf = try? String(contentsOf: dropIns.appendingPathComponent("000-kinhin-hardening.conf"), encoding: .utf8)
        return (process.terminationStatus, stderr, conf)
    }

    func testWritesTheDropInAndSucceedsWhenSshdAcceptsIt() throws {
        let result = try run(testExit: 0, effective: "passwordauthentication no")
        XCTAssertEqual(result.status, 0, result.stderr)
        let conf = try XCTUnwrap(result.conf)
        XCTAssertTrue(conf.contains("PasswordAuthentication no\n"))
        XCTAssertTrue(conf.contains("KbdInteractiveAuthentication no\n"))
        XCTAssertTrue(conf.contains("AuthenticationMethods publickey\n"))
    }

    func testFailsAndRemovesTheDropInWhenSshdRejectsTheConfig() throws {
        let result = try run(testExit: 1, effective: "passwordauthentication no")
        XCTAssertNotEqual(result.status, 0)
        XCTAssertTrue(result.stderr.contains("rejected"), result.stderr)
        XCTAssertNil(result.conf, "a config sshd refuses must not stay behind")
    }

    func testFailsClosedWhenSshdIgnoresTheDropIn() throws {
        let result = try run(testExit: 0, effective: "passwordauthentication yes")
        XCTAssertNotEqual(result.status, 0, "password login still on must fail the bake")
        XCTAssertTrue(result.stderr.contains("still on"), result.stderr)
    }
}
