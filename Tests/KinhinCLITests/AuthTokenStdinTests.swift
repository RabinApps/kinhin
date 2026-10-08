import XCTest

@testable import KinhinKit
@testable import kinhin

/// `auth set|add --token-stdin`: the token comes from stdin (never the command
/// line), and `--token X` keeps working with its warning.
final class AuthTokenStdinTests: XCTestCase {
    private var scratch: URL!

    override func setUpWithError() throws {
        scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("kinhin-auth-stdin-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        try "labels: [a]\n".write(to: configURL, atomically: true, encoding: .utf8)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: scratch)
    }

    private var configURL: URL { scratch.appendingPathComponent("config.yaml") }

    private func environment(stdin: String?, _ recorder: AuthRecorder) -> AuthEnvironment {
        var env = AuthEnvironment(
            save: { token, forge in recorder.recordSave(token, forge) },
            load: { _ in nil },
            delete: { _ in },
            readToken: { stdin },
            checkGitHub: { _ in },
            checkGitea: { _ in },
            loadConfig: { KinhinConfig.default },
            notifyDaemon: { token, forge in recorder.recordNotify(token, forge) },
            fail: { throw AuthTestSupport.AuthFailure(message: $0) },
            exit: { throw AuthTestSupport.AuthExit(code: $0) }
        )
        env.saveAccount = { token, forge, name in recorder.recordSaveAccount(token, forge, name) }
        env.notifyDaemonAccount = { recorder.recordNotifyAccount($0, $1) }
        env.configURL = configURL
        env.jsonConfig = .some(KinhinConfig.default)
        return env
    }

    func testSetReadsTheTokenFromStdinAndTrimsIt() async throws {
        let recorder = AuthRecorder()
        try await AuthCommand.run(
            ["auth", "set", "--token-stdin"], environment: environment(stdin: "  ghp_piped\n", recorder))
        XCTAssertEqual(recorder.saved.map(\.token), ["ghp_piped"])
        XCTAssertEqual(recorder.saved.map(\.forge), [.github])
        XCTAssertEqual(recorder.notified.map(\.token), ["ghp_piped"], "a running daemon is told")
    }

    func testSetStdinHonorsTheForgeFlag() async throws {
        let recorder = AuthRecorder()
        try await AuthCommand.run(
            ["auth", "set", "--gitea", "--token-stdin"], environment: environment(stdin: "gta_x", recorder))
        XCTAssertEqual(recorder.saved.map(\.forge), [.gitea])
    }

    func testEmptyStdinFailsWithoutSavingAnything() async {
        let recorder = AuthRecorder()
        for stdin in [nil, "", "  \n"] as [String?] {
            do {
                try await AuthCommand.run(
                    ["auth", "set", "--token-stdin"], environment: environment(stdin: stdin, recorder))
                XCTFail("expected a failure for stdin \(String(describing: stdin))")
            } catch let error as AuthTestSupport.AuthFailure {
                XCTAssertTrue(error.message.contains("no token on stdin"), error.message)
            } catch {
                XCTFail("unexpected \(error)")
            }
        }
        XCTAssertTrue(recorder.saved.isEmpty)
    }

    func testTokenAndTokenStdinTogetherAreAUsageError() async {
        let recorder = AuthRecorder()
        do {
            try await AuthCommand.run(
                ["auth", "set", "--token", "x", "--token-stdin"], environment: environment(stdin: "y", recorder))
            XCTFail("expected a usage error")
        } catch let error as CLIError {
            XCTAssertEqual(error.exit, .usage)
            XCTAssertTrue(error.message.contains("alternatives"), error.message)
        } catch {
            XCTFail("unexpected \(error)")
        }
        XCTAssertTrue(recorder.saved.isEmpty)
    }

    func testTheOldTokenFlagStillWorks() async throws {
        let recorder = AuthRecorder()
        try await AuthCommand.run(
            ["auth", "set", "--token", "ghp_old"], environment: environment(stdin: nil, recorder))
        XCTAssertEqual(recorder.saved.map(\.token), ["ghp_old"])
    }

    func testAddStoresTheStdinTokenForTheNewAccount() async throws {
        let recorder = AuthRecorder()
        try await AuthCommand.run(
            [
                "auth", "add", "ci", "--gitea", "--scope", "acme/widgets", "--instance", "https://g.example",
                "--token-stdin",
            ],
            environment: environment(stdin: "gta_ci\n", recorder))
        XCTAssertEqual(recorder.savedAccounts.map(\.token), ["gta_ci"])
        XCTAssertEqual(recorder.savedAccounts.map(\.name), ["ci"])
        let yaml = try String(contentsOf: configURL, encoding: .utf8)
        XCTAssertTrue(yaml.contains("ci"), "the account was added to the config")
    }

    func testAddWithEmptyStdinLeavesTheConfigUntouched() async throws {
        let recorder = AuthRecorder()
        do {
            try await AuthCommand.run(
                [
                    "auth", "add", "ci", "--gitea", "--scope", "acme/widgets", "--instance", "https://g.example",
                    "--token-stdin",
                ],
                environment: environment(stdin: "", recorder))
            XCTFail("expected a failure")
        } catch is AuthTestSupport.AuthFailure {
        }
        XCTAssertEqual(try String(contentsOf: configURL, encoding: .utf8), "labels: [a]\n")
        XCTAssertTrue(recorder.savedAccounts.isEmpty)
    }

    // MARK: - auth status --quiet

    func testQuietStatusStillExitsOneWhenNothingIsStored() async {
        let recorder = AuthRecorder()
        do {
            try await AuthCommand.run(["auth", "status", "--quiet"], environment: environment(stdin: nil, recorder))
            XCTFail("expected exit(1)")
        } catch let error as AuthTestSupport.AuthExit {
            XCTAssertEqual(error.code, 1)
        } catch {
            XCTFail("unexpected \(error)")
        }
    }

    func testQuietJSONStatusReturnsTheDocumentWithoutPrintingIt() throws {
        let recorder = AuthRecorder()
        let built = try AuthCommand.emitStatusJSON(environment: environment(stdin: nil, recorder), quiet: true)
        XCTAssertFalse(built.report.allGood)
        XCTAssertFalse(built.data.isEmpty)
    }
}
