import Synchronization
import XCTest

@testable import KinhinKit
@testable import KinhinTestSupport

/// Contract for `KeygenShell` as the stand-in for `/usr/bin/ssh-keygen`: the
/// generation path `GuestSSHKey.publicKey(in:shell:)` relies on must read
/// like the real binary — the same argv production issues (`-q -t ed25519
/// -N "" -C kinhin-guest -f <dir>/id_ed25519`), the `.pub` file appearing
/// exactly where production then reads it, and content that passes
/// `GuestSSHKey.validated` on both sides. The real side runs the real
/// `/usr/bin/ssh-keygen` through the real `Shell`; no network is involved.
/// The `-y` (derive-pub-from-private) path is deliberately out of scope:
/// `KeygenShell` models generation only, which is all its suite uses.
final class KeygenShellContractTests: XCTestCase {
    /// Captures the argv production issues while the real `Shell` (and the
    /// real `ssh-keygen`) answers it.
    private final class RecordingShell: ShellRunning, Sendable {
        private let box = Mutex<[[String]]>([])
        private let inner = Shell()
        var argvs: [[String]] { box.withLock { $0 } }

        func run(_ argv: [String], cwd: URL?, timeout: TimeInterval) async throws -> ShellResult {
            box.withLock { $0.append(argv) }
            return try await inner.run(argv, cwd: cwd, timeout: timeout)
        }

        func run(_ argv: [String], input: Data, cwd: URL?, timeout: TimeInterval) async throws -> ShellResult {
            box.withLock { $0.append(argv) }
            return try await inner.run(argv, input: input, cwd: cwd, timeout: timeout)
        }
    }

    private let goodKey = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIExampleExampleExampleExampleExample123 kinhin-guest"
    private var realDir: URL!
    private var fakeDir: URL!

    override func setUp() {
        let base = FileManager.default.temporaryDirectory
        realDir = base.appendingPathComponent("kinhin-keygen-real-\(UUID().uuidString)")
        fakeDir = base.appendingPathComponent("kinhin-keygen-fake-\(UUID().uuidString)")
    }

    override func tearDown() {
        // Scratch dirs of this test; nothing to report if already gone.
        try? FileManager.default.removeItem(at: realDir)
        try? FileManager.default.removeItem(at: fakeDir)
    }

    // MARK: - The argv production issues

    func testTheRealKeygenReceivesExactlyTheArgvTheFakeRecords() async throws {
        let recording = RecordingShell()
        let realKey = try await GuestSSHKey.publicKey(in: realDir, shell: recording)

        let fakeShell = KeygenShell(goodKey: goodKey)
        let fakeKey = try await GuestSSHKey.publicKey(in: fakeDir, shell: fakeShell)

        let realArgv = try XCTUnwrap(recording.argvs.first, "production must invoke ssh-keygen")
        let fakeArgv = try XCTUnwrap(fakeShell.argvs.first)
        /// The argv with its `-f` target normalized: the two legs run in
        /// their own scratch directories, which is the only allowed difference.
        func shape(_ argv: [String]) -> [String] {
            guard let dashF = argv.firstIndex(of: "-f") else { return argv }
            return Array(argv[0...dashF]) + ["<dir>/id_ed25519"]
        }
        XCTAssertEqual(
            shape(fakeArgv), shape(realArgv),
            "the fake must be handed the argv the real binary gets, so a change in either lands here")

        XCTAssertEqual(realArgv.first, "/usr/bin/ssh-keygen", "the production path is the system binary")
        XCTAssertTrue(realArgv.contains("ed25519"), "an ed25519 key, like the fake models")
        XCTAssertTrue(realArgv.contains("-N"), "an empty passphrase is what makes the key usable unattended")
        XCTAssertEqual(
            realArgv[realArgv.firstIndex(of: "-f")! + 1],
            realDir.appendingPathComponent("id_ed25519").path,
            "the -f target is the directory production then reads the .pub from")
        XCTAssertEqual(
            fakeArgv[fakeArgv.firstIndex(of: "-f")! + 1], fakeDir.appendingPathComponent("id_ed25519").path)
        XCTAssertEqual(fakeKey, goodKey, "the fake answers with the key it wrote")
        XCTAssertNotEqual(realKey, goodKey, "the real binary generated its own fresh key")
    }

    // MARK: - The file production reads

    func testThePubFileAppearsWhereProductionReadsItOnBothSides() async throws {
        let realKey = try await GuestSSHKey.publicKey(in: realDir, shell: Shell())
        let fakeKey = try await GuestSSHKey.publicKey(in: fakeDir, shell: KeygenShell(goodKey: goodKey))

        let realPub = realDir.appendingPathComponent("id_ed25519.pub")
        let fakePub = fakeDir.appendingPathComponent("id_ed25519.pub")
        XCTAssertTrue(FileManager.default.fileExists(atPath: realPub.path), "ssh-keygen wrote the public half")
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: fakePub.path),
            "the fake writes the same file at the same path — production reads it without checking who made it")

        let realContents = try String(contentsOf: realPub, encoding: .utf8)
        let fakeContents = try String(contentsOf: fakePub, encoding: .utf8)
        XCTAssertEqual(realContents.trimmingCharacters(in: .whitespacesAndNewlines), realKey)
        XCTAssertEqual(fakeContents.trimmingCharacters(in: .whitespacesAndNewlines), fakeKey)

        // Both keys are single ssh-ed25519 lines, safe inside the install script's quotes.
        XCTAssertEqual(try GuestSSHKey.validated(realContents), realKey)
        XCTAssertEqual(try GuestSSHKey.validated(fakeContents), fakeKey)
        XCTAssertTrue(realKey.hasPrefix("ssh-ed25519 "))
        XCTAssertTrue(fakeKey.hasPrefix("ssh-ed25519 "))
    }

    func testAFreshRealKeyPairIsUsableAndNeverTheCannedOne() async throws {
        // Two real generations are distinct keys (the fake's canned answer is
        // always the same string — that difference must stay visible).
        let first = try await GuestSSHKey.publicKey(in: realDir, shell: Shell())
        try? FileManager.default.removeItem(at: realDir)  // force a second generation
        let second = try await GuestSSHKey.publicKey(in: realDir, shell: Shell())

        XCTAssertNotEqual(first, second, "each real generation creates a new keypair")
        XCTAssertNotEqual(first, goodKey, "the real binary never answers with the fake's canned key")
        XCTAssertEqual(try GuestSSHKey.validated(first), first)
        XCTAssertEqual(try GuestSSHKey.validated(second), second)
    }
}
