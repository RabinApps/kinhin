import Synchronization
import XCTest

@testable import KinhinKit
@testable import kinhin

/// The `auth` command flows — set/status/clear for both forges — driven
/// entirely through an injected `AuthEnvironment`: no real Keychain, stdin,
/// network, or daemon socket. The fail/exit hooks throw catchable errors, so
/// tests assert on exit codes and messages without ever terminating xctest.
final class AuthCommandTests: XCTestCase {
    // MARK: - Recording doubles

    private struct AuthFailure: Error { let message: String }
    private struct AuthExit: Error { let code: Int }
    private struct SaveError: Error {}
    private struct CheckError: Error {}

    private struct Snapshot: Sendable {
        var events: [String] = []
        var saved: [(token: String, forge: ForgeID)] = []
        var deleted: [ForgeID] = []
        var notified: [(token: String, forge: ForgeID)] = []
        var checkedGitHub: [GitHubCredentials] = []
        var checkedGitea: [GiteaCredentials] = []
    }

    /// Recording double; all state is Mutex-guarded so its closures are
    /// `@Sendable` (AuthEnvironment requires Sendable closure fields).
    private final class Recorder: Sendable {
        private let state = Mutex(Snapshot())
        var events: [String] { state.withLock { $0.events } }
        var saved: [(token: String, forge: ForgeID)] { state.withLock { $0.saved } }
        var deleted: [ForgeID] { state.withLock { $0.deleted } }
        var notified: [(token: String, forge: ForgeID)] { state.withLock { $0.notified } }
        var checkedGitHub: [GitHubCredentials] { state.withLock { $0.checkedGitHub } }
        var checkedGitea: [GiteaCredentials] { state.withLock { $0.checkedGitea } }

        func append(_ keyPath: WritableKeyPath<Snapshot, [String]>, _ value: String) {
            state.withLock { $0[keyPath: keyPath] = $0[keyPath: keyPath] + [value] }
        }
        func recordSave(_ token: String, _ forge: ForgeID) {
            state.withLock {
                $0.saved.append((token, forge)); $0.events.append("save:\(forge.rawValue)")
            }
        }
        func recordDelete(_ forge: ForgeID) {
            state.withLock {
                $0.deleted.append(forge); $0.events.append("delete:\(forge.rawValue)")
            }
        }
        func recordNotify(_ token: String, _ forge: ForgeID) {
            state.withLock {
                $0.notified.append((token, forge)); $0.events.append("notify:\(forge.rawValue)")
            }
        }
        func recordCheck(_ forge: ForgeID, _ credentials: GitHubCredentials) {
            state.withLock {
                $0.checkedGitHub.append(credentials); $0.events.append("check:github")
            }
        }
        func recordCheck(_ forge: ForgeID, _ credentials: GiteaCredentials) {
            state.withLock {
                $0.checkedGitea.append(credentials); $0.events.append("check:gitea")
            }
        }
    }

    private func makeEnvironment(
        stored: [ForgeID: String] = [:],
        config: KinhinConfig,
        readToken: (@Sendable () -> String?)? = nil,
        checkError: Error? = nil,
        saveError: Error? = nil,
        _ recorder: Recorder
    ) -> AuthEnvironment {
        let frozen = config
        return AuthEnvironment(
            save: { token, forge in
                if let saveError { throw saveError }
                recorder.recordSave(token, forge)
            },
            load: { stored[$0] },
            delete: { forge in
                recorder.recordDelete(forge)
            },
            readToken: readToken ?? { nil },
            checkGitHub: { credentials in
                recorder.recordCheck(.github, credentials)
                if let checkError { throw checkError }
            },
            checkGitea: { credentials in
                recorder.recordCheck(.gitea, credentials)
                if let checkError { throw checkError }
            },
            loadConfig: { frozen },
            notifyDaemon: { token, forge in
                recorder.recordNotify(token, forge)
            },
            fail: { throw AuthFailure(message: $0) },
            exit: { throw AuthExit(code: $0) }
        )
    }

    private func workingConfig(gitea: Bool = false) -> KinhinConfig {
        var cfg = KinhinConfig.default
        cfg.accounts = [AccountConfig(name: "github", forge: .github, scope: "acme/widgets")]
        if gitea {
            cfg.accounts.append(
                AccountConfig(
                    name: "gitea", forge: .gitea, scope: "acme/widgets", instance: "https://gitea.example.com"))
        }
        return cfg
    }

    /// Runs the command expecting a `fail()` (stderr message + exit 1).
    private func expectFailure(
        _ args: [String],
        message expected: String,
        environment: AuthEnvironment,
        file: StaticString = #filePath, line: UInt = #line
    ) async {
        do {
            try await AuthCommand.run(args, environment: environment)
            XCTFail("expected fail() for \(args)", file: file, line: line)
        } catch let error as AuthFailure {
            XCTAssertEqual(error.message, expected, file: file, line: line)
        } catch {
            XCTFail("expected AuthFailure, got \(error)", file: file, line: line)
        }
    }

    /// Runs the command expecting a bare `exit(1)` (stdout already printed).
    private func expectExit1(
        _ args: [String],
        environment: AuthEnvironment,
        file: StaticString = #filePath, line: UInt = #line
    ) async {
        do {
            try await AuthCommand.run(args, environment: environment)
            XCTFail("expected exit(1) for \(args)", file: file, line: line)
        } catch let error as AuthExit {
            XCTAssertEqual(error.code, 1, file: file, line: line)
        } catch {
            XCTFail("expected AuthExit, got \(error)", file: file, line: line)
        }
    }

    // MARK: - set (explicit --token)

    func testSetExplicitTokenSavesAndNotifiesGitHub() async throws {
        let recorder = Recorder()
        let env = makeEnvironment(config: workingConfig(), recorder)

        try await AuthCommand.run(["auth", "set", "--token", "ghp_abc123"], environment: env)

        XCTAssertEqual(recorder.saved.count, 1)
        XCTAssertEqual(recorder.saved[0].token, "ghp_abc123")
        XCTAssertEqual(recorder.saved[0].forge, .github)
        XCTAssertEqual(recorder.notified.map(\.token), ["ghp_abc123"])
        XCTAssertEqual(recorder.notified.map(\.forge), [.github])
    }

    func testSetExplicitGiteaTokenSavesAndNotifiesGitea() async throws {
        let recorder = Recorder()
        let env = makeEnvironment(config: workingConfig(gitea: true), recorder)

        try await AuthCommand.run(["auth", "set", "--gitea", "--token", "gt_secret"], environment: env)

        XCTAssertEqual(recorder.saved.map(\.forge), [.gitea])
        XCTAssertEqual(recorder.notified.map(\.forge), [.gitea])
        // No forge probe on `set` — storing is all it does.
        XCTAssertTrue(recorder.checkedGitHub.isEmpty && recorder.checkedGitea.isEmpty)
    }

    func testGiteaFlagIsPositionIndependent() async throws {
        // --gitea is scanned from the whole arg list, not just the head.
        let recorder = Recorder()
        let env = makeEnvironment(config: workingConfig(gitea: true), recorder)

        try await AuthCommand.run(["auth", "set", "--token", "gt_1", "--gitea"], environment: env)

        XCTAssertEqual(recorder.saved.map(\.forge), [.gitea])
    }

    func testSaveThenNotifyHappensInOrder() async throws {
        let recorder = Recorder()
        let env = makeEnvironment(config: workingConfig(), recorder)

        try await AuthCommand.run(["auth", "set", "--token", "t"], environment: env)

        XCTAssertEqual(recorder.events, ["save:github", "notify:github"])
    }

    // MARK: - set (hidden input)

    func testSetReadsHiddenInputAndTrimsIt() async throws {
        let recorder = Recorder()
        let env = makeEnvironment(
            config: workingConfig(),
            readToken: { "  ghp_pasted \n" },
            recorder
        )

        try await AuthCommand.run(["auth", "set"], environment: env)

        // The pasted line is trimmed before storing — whitespace must never
        // end up inside the Keychain secret.
        XCTAssertEqual(recorder.saved.map(\.token), ["ghp_pasted"])
    }

    func testSetWithBlankInputFailsWithoutSaving() async {
        let recorder = Recorder()
        let env = makeEnvironment(config: workingConfig(), readToken: { "   " }, recorder)

        await expectFailure(["auth", "set"], message: "no token entered", environment: env)

        XCTAssertTrue(recorder.saved.isEmpty, "nothing is stored when no token was entered")
        XCTAssertTrue(recorder.notified.isEmpty)
    }

    func testSetWithClosedInputFails() async {
        let recorder = Recorder()
        let env = makeEnvironment(config: workingConfig(), readToken: { nil }, recorder)

        await expectFailure(["auth", "set"], message: "no token entered", environment: env)

        XCTAssertTrue(recorder.saved.isEmpty)
    }

    // MARK: - set (failure propagation)

    func testSaveFailurePropagatesAndSkipsNotification() async {
        let recorder = Recorder()
        let env = makeEnvironment(config: workingConfig(), saveError: SaveError(), recorder)

        do {
            try await AuthCommand.run(["auth", "set", "--token", "t"], environment: env)
            XCTFail("expected the save error to propagate")
        } catch is SaveError {
            // propagated untouched — the CLI's top-level handler prints it
        } catch {
            XCTFail("unexpected error \(error)")
        }
        XCTAssertTrue(recorder.notified.isEmpty, "a failed save must not notify the daemon")
        XCTAssertTrue(recorder.events.isEmpty)
    }

    // MARK: - status (GitHub)

    func testStatusWithoutStoredTokenExits1() async {
        let recorder = Recorder()
        let env = makeEnvironment(config: workingConfig(), recorder)

        await expectExit1(["auth", "status"], environment: env)

        XCTAssertTrue(recorder.checkedGitHub.isEmpty, "no probe runs when nothing is stored")
    }

    func testStatusProbesWithStoredTokenAndConfiguredScope() async throws {
        let recorder = Recorder()
        let env = makeEnvironment(
            stored: [.github: "ghp_live"],
            config: workingConfig(),
            recorder
        )

        try await AuthCommand.run(["auth", "status"], environment: env)

        XCTAssertEqual(recorder.checkedGitHub.count, 1)
        XCTAssertEqual(recorder.checkedGitHub[0].token, "ghp_live")
        XCTAssertEqual(recorder.checkedGitHub[0].scope, "acme/widgets")
    }

    func testStatusCheckFailureExits1() async {
        let recorder = Recorder()
        let env = makeEnvironment(
            stored: [.github: "ghp_dead"],
            config: workingConfig(),
            checkError: CheckError(),
            recorder
        )

        await expectExit1(["auth", "status"], environment: env)
        XCTAssertEqual(recorder.checkedGitHub.count, 1, "the probe ran and was allowed to fail")
    }

    // MARK: - status (Gitea)

    func testGiteaStatusWithoutStoredTokenExits1() async {
        let recorder = Recorder()
        let env = makeEnvironment(config: workingConfig(gitea: true), recorder)

        await expectExit1(["auth", "status", "--gitea"], environment: env)

        XCTAssertTrue(recorder.checkedGitea.isEmpty)
    }

    func testGiteaStatusWithoutGiteaConfigSectionFails() async {
        let recorder = Recorder()
        let env = makeEnvironment(stored: [.gitea: "gt_live"], config: workingConfig(), recorder)

        await expectFailure(
            ["auth", "status", "--gitea"],
            message: "no gitea section in config — add it before checking the Gitea token",
            environment: env
        )
        XCTAssertTrue(recorder.checkedGitea.isEmpty)
    }

    func testGiteaStatusProbesWithStoredTokenInstanceAndScope() async throws {
        let recorder = Recorder()
        let env = makeEnvironment(
            stored: [.gitea: "gt_live"],
            config: workingConfig(gitea: true),
            recorder
        )

        try await AuthCommand.run(["auth", "status", "--gitea"], environment: env)

        XCTAssertEqual(recorder.checkedGitea.count, 1)
        XCTAssertEqual(recorder.checkedGitea[0].token, "gt_live")
        XCTAssertEqual(recorder.checkedGitea[0].scope, "acme/widgets")
        XCTAssertEqual(recorder.checkedGitea[0].instance, "https://gitea.example.com")
    }

    func testGiteaStatusCheckFailureExits1() async {
        let recorder = Recorder()
        let env = makeEnvironment(
            stored: [.gitea: "gt_dead"],
            config: workingConfig(gitea: true),
            checkError: CheckError(),
            recorder
        )

        await expectExit1(["auth", "status", "--gitea"], environment: env)
    }

    // MARK: - clear

    func testClearDeletesGitHubToken() async throws {
        let recorder = Recorder()
        let env = makeEnvironment(stored: [.github: "t"], config: workingConfig(), recorder)

        try await AuthCommand.run(["auth", "clear"], environment: env)

        XCTAssertEqual(recorder.deleted, [.github])
        XCTAssertTrue(recorder.notified.isEmpty, "clearing must not notify the daemon")
    }

    func testClearGiteaDeletesGiteaToken() async throws {
        let recorder = Recorder()
        let env = makeEnvironment(config: workingConfig(), recorder)

        try await AuthCommand.run(["auth", "clear", "--gitea"], environment: env)

        XCTAssertEqual(recorder.deleted, [.gitea])
    }

    // MARK: - subcommand parsing quirks

    func testBareAuthBehavesLikeSet() async throws {
        let recorder = Recorder()
        let env = makeEnvironment(config: workingConfig(), readToken: { "tok" }, recorder)

        try await AuthCommand.run(["auth"], environment: env)

        XCTAssertEqual(recorder.saved.map(\.token), ["tok"])
    }

    func testUnknownSubcommandFails() async {
        let recorder = Recorder()
        let env = makeEnvironment(config: workingConfig(), recorder)

        await expectFailure(
            ["auth", "frobnicate"],
            message: "unknown auth subcommand 'frobnicate' (use set|status|clear|list|add|remove)",
            environment: env
        )
    }

    func testTokenFlagWithoutSetSubcommandFails() async {
        // Historical quirk pinned: only the head token selects the
        // subcommand, so `kinhin auth --token X` (no "set") is an unknown
        // subcommand, not a set. The flag must follow "set".
        let recorder = Recorder()
        let env = makeEnvironment(config: workingConfig(), recorder)

        await expectFailure(
            ["auth", "--token", "ghp_x"],
            message: "unknown auth subcommand '--token' (use set|status|clear|list|add|remove)",
            environment: env
        )
        XCTAssertTrue(recorder.saved.isEmpty)
    }
}
