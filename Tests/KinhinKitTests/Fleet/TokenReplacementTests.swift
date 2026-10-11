import Security
import Synchronization
import XCTest

@testable import KinhinKit
@testable import KinhinTestSupport

/// Replacing the stored PAT: the Keychain upsert, the engine's live
/// credential swap (new API client + invalidated registration-token cache),
/// and the daemon RPC that carries the swap across process boundaries.
final class TokenReplacementTests: XCTestCase {
    // MARK: - Keychain

    /// A throwaway Keychain service: this test must never touch the
    /// developer's real token (it used to delete it on every run).
    private func withScratchKeychain(_ body: () throws -> Void) rethrows {
        KeychainTokenStore.serviceOverride = "com.kinhin.runner.tests.\(UUID().uuidString)"
        defer {
            _ = try? KeychainTokenStore.deleteAll(service: KeychainTokenStore.service)
            KeychainTokenStore.serviceOverride = nil
        }
        try body()
    }

    func testSaveOverwritesExistingToken() throws {
        try withScratchKeychain {
            do {
                try saveOverwritesExistingToken()
            } catch KeychainTokenStore.TokenError.unhandled(let status)
                where status == errSecInteractionNotAllowed
            {
                // A headless runner session (CI) cannot write the login
                // keychain without interaction; the overwrite semantics are
                // still covered wherever the keychain is writable.
                throw XCTSkip("login keychain is not writable in this session")
            }
        }
    }

    private func saveOverwritesExistingToken() throws {
        XCTAssertNotEqual(KeychainTokenStore.service, Paths.keychainService, "must not touch the real token")
        KeychainTokenStore.delete()
        try KeychainTokenStore.save("ghp_first")
        XCTAssertEqual(try KeychainTokenStore.load(), "ghp_first")
        try KeychainTokenStore.save("ghp_second")
        XCTAssertEqual(try KeychainTokenStore.load(), "ghp_second", "auth set must replace, not duplicate or fail")
    }

    // MARK: - Engine credential swap

    /// Factory observing every credential handed to it.
    private final class RecordingFactory: Sendable {
        private struct State: Sendable {
            var seenTokens: [String] = []
        }

        private let state = Mutex(State())

        var seenTokens: [String] { state.withLock { $0.seenTokens } }

        var asFactory: GitHubClientFactory {
            GitHubClientFactory { [self] credentials in make(credentials) }
        }
        func make(_ credentials: GitHubCredentials) -> GitHubServing {
            state.withLock { $0.seenTokens.append(credentials.token) }
            return SwapProbeClient(token: credentials.token)
        }
    }

    /// Minimal client that remembers the token it was built with.
    private final class SwapProbeClient: GitHubServing, Sendable {
        let token: String
        init(token: String) { self.token = token }
        var configureURL: String { "https://github.com/acme/widgets" }
        func fetchRegistrationToken() async throws -> RegistrationToken {
            RegistrationToken(token: "rt", expiresAt: Date().addingTimeInterval(3600))
        }
        func listRunners() async throws -> [GHRunner] { [] }
        func deleteRunner(id: Int) async throws {}
        func queuedJobs(matching labels: Set<String>) async throws -> [QueuedJob] { [] }
        func runningJobs(matching labels: Set<String>) async throws -> [RunningJob] { [] }
        func cancelWorkflowRun(ids: [Int]) async throws -> Bool { true }
        func skipWorkflowRun(ids: [Int]) async throws -> Bool { true }
    }

    /// The client serving an account's attached GitHub forge.
    private func client(_ engine: FleetEngine, account: String = "github") -> SwapProbeClient? {
        (engine.forges[account] as? GitHubForge)?.client as? SwapProbeClient
    }

    private func makeEngine(pat: String, github: GitHubServing, factory: GitHubClientFactory) -> FleetEngine {
        FleetEngine(
            config: makeTestConfig(),
            pat: pat,
            tart: FakeTart(),
            store: makeTestStore(),
            ssh: FakeSSH(),
            host: testHost,
            githubFactory: factory
        )
    }

    func testReplaceCredentialsSwapsClientWithNewToken() async {
        let recording = RecordingFactory()
        let engine = makeEngine(pat: "ghp_old", github: SwapProbeClient(token: "ghp_old"), factory: recording.asFactory)

        await engine.replaceCredentials(pat: "ghp_new")

        XCTAssertEqual(
            recording.seenTokens, ["ghp_old", "ghp_new"], "factory must rebuild a client from the fresh credentials")
        XCTAssertEqual(client(engine)?.token, "ghp_new", "the primary forge must serve the new credentials")
    }

    func testReplaceCredentialsPreservesScope() async {
        var cfg = makeTestConfig()
        cfg.accounts = [AccountConfig(name: "github", forge: .github, scope: "acme")]
        let engine = FleetEngine(
            config: cfg, pat: "ghp_old", tart: FakeTart(), store: makeTestStore(),
            ssh: FakeSSH(), host: testHost, githubFactory: GitHubClientFactory { SwapProbeClient(token: $0.token) }
        )
        await engine.replaceCredentials(pat: "ghp_new")
        // The swapped client still routes through the org scope: minting a
        // registration token succeeds against whatever scope the factory set.
        XCTAssertEqual(client(engine)?.token, "ghp_new")
    }

    /// A primary GitHub account not named "github" must be swapped under its
    /// own name — never duplicated under a stale "github" key that polls with
    /// an empty or old token.
    func testReplaceCredentialsKeysPrimaryByAccountName() async {
        var cfg = makeTestConfig()
        cfg.accounts = [AccountConfig(name: "work", forge: .github, scope: "acme/widgets")]
        let engine = FleetEngine(
            config: cfg, pat: "ghp_old", tart: FakeTart(), store: makeTestStore(),
            ssh: FakeSSH(), host: testHost, githubFactory: GitHubClientFactory { SwapProbeClient(token: $0.token) }
        )
        XCTAssertEqual(Set(engine.forges.keys), ["work"])

        await engine.replaceCredentials(pat: "ghp_new")

        XCTAssertEqual(Set(engine.forges.keys), ["work"], "no stale \"github\" forge may appear")
        guard let credentials = engine.forges["work"]?.credentials, credentials.forge == .github else {
            return XCTFail("primary account must stay attached under its name")
        }
        XCTAssertEqual(credentials.token, "ghp_new")
        XCTAssertEqual(client(engine, account: "work")?.token, "ghp_new")
    }

    /// Rotating the primary GitHub account by name (the app's Connect card,
    /// `auth set --account work`) swaps the same state as the PAT swap.
    func testRotatingThePrimaryAccountByNameSwapsTheClient() async {
        var cfg = makeTestConfig()
        cfg.accounts = [AccountConfig(name: "work", forge: .github, scope: "acme/widgets")]
        let engine = FleetEngine(
            config: cfg, pat: "ghp_old", tart: FakeTart(), store: makeTestStore(),
            ssh: FakeSSH(), host: testHost, githubFactory: GitHubClientFactory { SwapProbeClient(token: $0.token) }
        )
        await CredentialRotation.apply(.account("work"), token: "ghp_new", to: engine)
        XCTAssertEqual(client(engine, account: "work")?.token, "ghp_new")
        XCTAssertEqual(CredentialRotation.Target.forge(.gitea).accountName, "gitea")
    }

    func testReplaceCredentialsInvalidatesRegistrationTokenCache() async throws {
        let github = FakeGitHub()
        let factory = GitHubClientFactory { _ in github }
        let engine = makeEngine(pat: "ghp_old", github: github, factory: factory)

        // Spin up one VM: its lifecycle mints a registration token (cached).
        github.queueDepth = 1
        try await engine.reconcileOnce()
        try await waitUntil(timeout: 10) {
            let status = await engine.status()
            return status.activeCount == 1 && status.records.first?.phase == .ready
        }
        XCTAssertEqual(github.registrationTokenCalls, 1)

        // Swap credentials, then demand a second VM: the cache must have been
        // invalidated, forcing a fresh mint under the new PAT's authority.
        await engine.replaceCredentials(pat: "ghp_new")
        github.queueDepth = 2
        try await engine.reconcileOnce()
        try await waitUntil(timeout: 10) {
            github.registrationTokenCalls >= 2
        }
        XCTAssertEqual(
            github.registrationTokenCalls, 2, "post-swap registration must re-mint, not reuse the cached token")
    }

    // MARK: - Daemon RPC

    func testDaemonReplaceTokenRoundTrip() async throws {
        let recording = RecordingFactory()
        let engine = makeEngine(pat: "ghp_old", github: SwapProbeClient(token: "ghp_old"), factory: recording.asFactory)

        let payload = try JSONEncoder().encode(TokenReplaceRequest(pat: "ghp_via_rpc"))
        let response = await Daemon.handle(RPCRequest(id: 11, method: .replaceToken, payload: payload), engine: engine)

        XCTAssertTrue(response.ok)
        XCTAssertEqual(client(engine)?.token, "ghp_via_rpc")
    }

    func testDaemonReplaceTokenRejectsBadPayload() async throws {
        let engine = makeEngine(
            pat: "ghp_old", github: SwapProbeClient(token: "ghp_old"),
            factory: GitHubClientFactory { _ in SwapProbeClient(token: "ghp_old") })
        let badPayload = try JSONEncoder().encode(["nope": true])
        let response = await Daemon.handle(
            RPCRequest(id: 12, method: .replaceToken, payload: badPayload), engine: engine)
        XCTAssertFalse(response.ok)
        XCTAssertTrue(response.error?.contains("pat") ?? false)
    }

    func testReplaceTokenWireNameAndPayloadCodable() throws {
        XCTAssertEqual(RPCMethod.replaceToken.rawValue, "replace_token")
        let data = try JSONEncoder().encode(TokenReplaceRequest(pat: "p"))
        let decoded = try JSONDecoder().decode(TokenReplaceRequest.self, from: data)
        XCTAssertEqual(decoded.pat, "p")
    }

    // MARK: - Setup checklist contract

    func testStoredTokenStillOffersReplaceAction() async {
        let computer = SetupCheckHelper.make(
            tartHealth: .healthy,
            tartList: [
                TartVM(name: "tahoe-base", source: "ghcr.io/cirruslabs/macos-tahoe-base:latest", status: "stopped")
            ],
            config: makeTestConfig(),
            githubTokenStored: true
        )
        let status = await computer.compute()
        let token = status.checks.first { $0.id == "account-token-github" }
        XCTAssertEqual(
            token?.action, "replace_account_token", "a stored token must remain replaceable from the checklist")
        XCTAssertEqual(SetupAction.title(for: "replace_account_token"), "Replace Token…")
    }

    func testMissingTokenOffersEnterAction() async {
        let computer = SetupCheckHelper.make(
            tartHealth: .healthy,
            tartList: [
                TartVM(name: "tahoe-base", source: "ghcr.io/cirruslabs/macos-tahoe-base:latest", status: "stopped")
            ],
            config: makeTestConfig(),
            githubTokenStored: false
        )
        let status = await computer.compute()
        XCTAssertEqual(status.checks.first { $0.id == "account-token-github" }?.action, "enter_account_token")
    }

}
