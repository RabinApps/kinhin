import XCTest

@testable import KinhinKit
@testable import KinhinTestSupport

final class GuestSSHKeyTests: XCTestCase {
    private let goodKey = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIExampleExampleExampleExampleExample123 kinhin-guest"
    private var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("kinhin-sshkey-\(UUID().uuidString)")
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: dir)  // scratch dir of this test; nothing to report if already gone
    }

    func testValidationAcceptsOneKeyLineAndRejectsAnythingElse() throws {
        XCTAssertEqual(try GuestSSHKey.validated(goodKey + "\n"), goodKey)
        for bad in [
            "", "ssh-dss AAAA", goodKey + "\nssh-ed25519 BBBB", "ssh-ed25519 AAAA'; rm -rf / #",
            "ssh-ed25519 AAAA kinhin guest",
        ] {
            XCTAssertThrowsError(try GuestSSHKey.validated(bad), bad)
        }
    }

    func testInstallScriptIsIdempotentAndQuotesTheKey() {
        let script = GuestSSHKey.installScript(publicKey: goodKey, user: "admin")
        XCTAssertTrue(script.contains("~admin"))
        XCTAssertTrue(script.contains("grep -qxF '\(goodKey)'"), "append only when absent")
        XCTAssertTrue(script.contains("chmod 600"))
    }

    func testAnExistingKeyIsReusedWithoutRunningAnything() async throws {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try "private".write(to: dir.appendingPathComponent("id_ed25519"), atomically: true, encoding: .utf8)
        try goodKey.write(to: dir.appendingPathComponent("id_ed25519.pub"), atomically: true, encoding: .utf8)
        let shell = FakeShell()
        let key = try await GuestSSHKey.publicKey(in: dir, shell: shell)
        XCTAssertEqual(key, goodKey)
        XCTAssertTrue(shell.calls.isEmpty)
    }

    func testAMissingKeyIsGeneratedAsEd25519() async throws {
        let shell = KeygenShell(goodKey: goodKey)
        let key = try await GuestSSHKey.publicKey(in: dir, shell: shell)
        XCTAssertEqual(key, goodKey)
        let argv = try XCTUnwrap(shell.argvs.first)
        XCTAssertEqual(argv.first, "/usr/bin/ssh-keygen")
        XCTAssertTrue(argv.contains("ed25519"))
        XCTAssertTrue(argv.contains(dir.appendingPathComponent("id_ed25519").path))
    }

    func testTheControllerInstallsTheKeyThroughTartExec() async throws {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try "private".write(to: dir.appendingPathComponent("id_ed25519"), atomically: true, encoding: .utf8)
        try goodKey.write(to: dir.appendingPathComponent("id_ed25519.pub"), atomically: true, encoding: .utf8)
        let shell = FakeShell()
        var controller = try TartController(configuredPath: "/usr/bin/true", shell: shell)
        controller.guestKeyDirectory = dir
        try await controller.installGuestSSHKey(vm: "scratch", user: "admin")
        let argv = try XCTUnwrap(shell.calls.first)
        XCTAssertEqual(Array(argv.prefix(5)), ["/usr/bin/true", "exec", "scratch", "bash", "-c"])
        XCTAssertTrue(argv.last?.contains(goodKey) == true)
    }

    func testTheControllerRefusesAnUnsafeUser() async throws {
        var controller = try TartController(configuredPath: "/usr/bin/true", shell: FakeShell())
        controller.guestKeyDirectory = dir
        do {
            try await controller.installGuestSSHKey(vm: "scratch", user: "-oProxyCommand=x")
            XCTFail("expected a refusal")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("unsafe"), error.localizedDescription)
        }
    }
}

/// Models `ssh-keygen -f <path>`: writes the `.pub` file next to the private key.
final class KeygenShell: ShellRunning, @unchecked Sendable {
    let goodKey: String
    private(set) var argvs: [[String]] = []
    init(goodKey: String) { self.goodKey = goodKey }

    func run(_ argv: [String], cwd: URL?, timeout: TimeInterval) async throws -> ShellResult {
        argvs.append(argv)
        if let i = argv.firstIndex(of: "-f"), i + 1 < argv.count {
            try goodKey.write(toFile: argv[i + 1] + ".pub", atomically: true, encoding: .utf8)
        }
        return ShellResult(exitCode: 0, stdout: "", stderr: "")
    }
}
