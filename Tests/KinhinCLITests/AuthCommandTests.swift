import XCTest

@testable import KinhinKit
@testable import kinhin

/// The `auth` command flows — set/status/clear for both forges — driven
/// entirely through an injected `AuthEnvironment`: no real Keychain, stdin,
/// network, or daemon socket. The fail/exit hooks throw catchable errors, so
/// tests assert on exit codes and messages without ever terminating xctest.
final class AuthCommandTests: XCTestCase {
    // MARK: - Recording doubles

    // The error types, the recorder, and the environment builder are shared
    // with AuthAccountsCommandTests (see AuthTestSupport.swift).
    private func makeEnvironment(
        stored: [ForgeID: String] = [:],
        config: KinhinConfig,
        readToken: (@Sendable () -> String?)? = nil,
        checkError: Error? = nil,
        saveError: Error? = nil,
        _ recorder: AuthRecorder
    ) -> AuthEnvironment {
        makeRecorderEnvironment(
            stored: stored, config: config, readToken: readToken, checkError: checkError,
            saveError: saveError, recorder: recorder)
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
        } catch let error as AuthTestSupport.AuthFailure {
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
        } catch let error as AuthTestSupport.AuthExit {
            XCTAssertEqual(error.code, 1, file: file, line: line)
        } catch {
            XCTFail("expected AuthExit, got \(error)", file: file, line: line)
        }
    }

    // MARK: - set (explicit --token)

    func testSetExplicitTokenSavesAndNotifiesGitHub() async throws {
        let recorder = AuthRecorder()
        let env = makeEnvironment(config: workingConfig(), recorder)

        try await AuthCommand.run(["auth", "set", "--token", "ghp_abc123"], environment: env)

        XCTAssertEqual(recorder.saved.count, 1)
        XCTAssertEqual(recorder.saved[0].token, "ghp_abc123")
        XCTAssertEqual(recorder.saved[0].forge, .github)
        XCTAssertEqual(recorder.notified.map(\.token), ["ghp_abc123"])
        XCTAssertEqual(recorder.notified.map(\.forge), [.github])
    }

    func testSetExplicitGiteaTokenSavesAndNotifiesGitea() async throws {
        let recorder = AuthRecorder()
        let env = makeEnvironment(config: workingConfig(gitea: true), recorder)

        try await AuthCommand.run(["auth", "set", "--gitea", "--token", "gt_secret"], environment: env)

        XCTAssertEqual(recorder.saved.map(\.forge), [.gitea])
        XCTAssertEqual(recorder.notified.map(\.forge), [.gitea])
        // No forge probe on `set` — storing is all it does.
        XCTAssertTrue(recorder.checkedGitHub.isEmpty && recorder.checkedGitea.isEmpty)
    }

    func testGiteaFlagIsPositionIndependent() async throws {
        // --gitea is scanned from the whole arg list, not just the head.
        let recorder = AuthRecorder()
        let env = makeEnvironment(config: workingConfig(gitea: true), recorder)

        try await AuthCommand.run(["auth", "set", "--token", "gt_1", "--gitea"], environment: env)

        XCTAssertEqual(recorder.saved.map(\.forge), [.gitea])
    }

    func testSaveThenNotifyHappensInOrder() async throws {
        let recorder = AuthRecorder()
        let env = makeEnvironment(config: workingConfig(), recorder)

        try await AuthCommand.run(["auth", "set", "--token", "t"], environment: env)

        XCTAssertEqual(recorder.events, ["save:github", "notify:github"])
    }

    // MARK: - set (hidden input)

    func testSetReadsHiddenInputAndTrimsIt() async throws {
        let recorder = AuthRecorder()
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
        let recorder = AuthRecorder()
        let env = makeEnvironment(config: workingConfig(), readToken: { "   " }, recorder)

        await expectFailure(["auth", "set"], message: "no token entered", environment: env)

        XCTAssertTrue(recorder.saved.isEmpty, "nothing is stored when no token was entered")
        XCTAssertTrue(recorder.notified.isEmpty)
    }

    func testSetWithClosedInputFails() async {
        let recorder = AuthRecorder()
        let env = makeEnvironment(config: workingConfig(), readToken: { nil }, recorder)

        await expectFailure(["auth", "set"], message: "no token entered", environment: env)

        XCTAssertTrue(recorder.saved.isEmpty)
    }

    // MARK: - set (failure propagation)

    func testSaveFailurePropagatesAndSkipsNotification() async {
        let recorder = AuthRecorder()
        let env = makeEnvironment(config: workingConfig(), saveError: AuthTestSupport.SaveError(), recorder)

        do {
            try await AuthCommand.run(["auth", "set", "--token", "t"], environment: env)
            XCTFail("expected the save error to propagate")
        } catch is AuthTestSupport.SaveError {
            // propagated untouched — the CLI's top-level handler prints it
        } catch {
            XCTFail("unexpected error \(error)")
        }
        XCTAssertTrue(recorder.notified.isEmpty, "a failed save must not notify the daemon")
        XCTAssertTrue(recorder.events.isEmpty)
    }

    // MARK: - status (GitHub)

    func testStatusWithoutStoredTokenExits1() async {
        let recorder = AuthRecorder()
        let env = makeEnvironment(config: workingConfig(), recorder)

        await expectExit1(["auth", "status"], environment: env)

        XCTAssertTrue(recorder.checkedGitHub.isEmpty, "no probe runs when nothing is stored")
    }

    func testStatusProbesWithStoredTokenAndConfiguredScope() async throws {
        let recorder = AuthRecorder()
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

    func testStatusProbesTheConfiguredEnterpriseInstance() async throws {
        let recorder = AuthRecorder()
        var cfg = KinhinConfig.default
        cfg.accounts = [
            AccountConfig(
                name: "github", forge: .github, scope: "acme/widgets",
                instance: "https://github.example.com")
        ]
        let env = makeEnvironment(stored: [.github: "ghp_live"], config: cfg, recorder)

        try await AuthCommand.run(["auth", "status"], environment: env)

        XCTAssertEqual(recorder.checkedGitHub.count, 1)
        XCTAssertEqual(recorder.checkedGitHub[0].instance, "https://github.example.com")
    }

    func testStatusCheckFailureExits1() async {
        let recorder = AuthRecorder()
        let env = makeEnvironment(
            stored: [.github: "ghp_dead"],
            config: workingConfig(),
            checkError: AuthTestSupport.CheckError(),
            recorder
        )

        await expectExit1(["auth", "status"], environment: env)
        XCTAssertEqual(recorder.checkedGitHub.count, 1, "the probe ran and was allowed to fail")
    }

    // MARK: - status (Gitea)

    func testGiteaStatusWithoutStoredTokenExits1() async {
        let recorder = AuthRecorder()
        let env = makeEnvironment(config: workingConfig(gitea: true), recorder)

        await expectExit1(["auth", "status", "--gitea"], environment: env)

        XCTAssertTrue(recorder.checkedGitea.isEmpty)
    }

    func testGiteaStatusWithoutGiteaConfigSectionFails() async {
        let recorder = AuthRecorder()
        let env = makeEnvironment(stored: [.gitea: "gt_live"], config: workingConfig(), recorder)

        await expectFailure(
            ["auth", "status", "--gitea"],
            message: "no gitea account in config — add one before checking the Gitea token",
            environment: env
        )
        XCTAssertTrue(recorder.checkedGitea.isEmpty)
    }

    func testGiteaStatusProbesWithStoredTokenInstanceAndScope() async throws {
        let recorder = AuthRecorder()
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

    /// --forgejo checks the Forgejo account, never the Gitea one.
    func testForgejoStatusProbesTheForgejoAccount() async throws {
        let recorder = AuthRecorder()
        var cfg = workingConfig(gitea: true)
        cfg.accounts.append(
            AccountConfig(name: "forgejo", forge: .forgejo, scope: "team/app", instance: "https://codeberg.example"))
        let env = makeEnvironment(stored: [.forgejo: "fj_live"], config: cfg, recorder)

        try await AuthCommand.run(["auth", "status", "--forgejo"], environment: env)

        XCTAssertEqual(recorder.checkedGitea.count, 1)
        XCTAssertEqual(recorder.checkedGitea[0].token, "fj_live")
        XCTAssertEqual(recorder.checkedGitea[0].scope, "team/app")
        XCTAssertEqual(recorder.checkedGitea[0].instance, "https://codeberg.example")
    }

    func testGiteaStatusCheckFailureExits1() async {
        let recorder = AuthRecorder()
        let env = makeEnvironment(
            stored: [.gitea: "gt_dead"],
            config: workingConfig(gitea: true),
            checkError: AuthTestSupport.CheckError(),
            recorder
        )

        await expectExit1(["auth", "status", "--gitea"], environment: env)
    }

    // MARK: - clear

    func testClearDeletesGitHubToken() async throws {
        let recorder = AuthRecorder()
        let env = makeEnvironment(stored: [.github: "t"], config: workingConfig(), recorder)

        try await AuthCommand.run(["auth", "clear"], environment: env)

        XCTAssertEqual(recorder.deleted, [.github])
        XCTAssertTrue(recorder.notified.isEmpty, "clearing must not notify the daemon")
    }

    func testClearGiteaDeletesGiteaToken() async throws {
        let recorder = AuthRecorder()
        let env = makeEnvironment(config: workingConfig(), recorder)

        try await AuthCommand.run(["auth", "clear", "--gitea"], environment: env)

        XCTAssertEqual(recorder.deleted, [.gitea])
    }

    // MARK: - subcommand parsing quirks

    func testBareAuthBehavesLikeSet() async throws {
        let recorder = AuthRecorder()
        let env = makeEnvironment(config: workingConfig(), readToken: { "tok" }, recorder)

        try await AuthCommand.run(["auth"], environment: env)

        XCTAssertEqual(recorder.saved.map(\.token), ["tok"])
    }

    func testUnknownSubcommandFails() async {
        let recorder = AuthRecorder()
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
        let recorder = AuthRecorder()
        let env = makeEnvironment(config: workingConfig(), recorder)

        await expectFailure(
            ["auth", "--token", "ghp_x"],
            message: "unknown auth subcommand '--token' (use set|status|clear|list|add|remove)",
            environment: env
        )
        XCTAssertTrue(recorder.saved.isEmpty)
    }
}
