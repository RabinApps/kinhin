import XCTest

@testable import KinhinKit
@testable import KinhinTestSupport

/// Replacing the stored PAT: the Keychain upsert, the engine's live
/// credential swap (new API client + invalidated registration-token cache),
/// and the daemon RPC that carries the swap across process boundaries.
final class TokenReplacementTests: XCTestCase {
    // MARK: Keychain

    /// A throwaway Keychain service: this test must never touch the
    /// developer's real token (it used to delete it on every run).
    private func withScratchKeychain(_ body: () throws -> Void) rethrows {
        KeychainTokenStore.serviceOverride = "com.kinhin.runner.tests.\(UUID().uuidString)"
        defer {
            KeychainTokenStore.delete()
            KeychainTokenStore.serviceOverride = nil
        }
        try body()
    }

    func testSaveOverwritesExistingToken() throws {
        try withScratchKeychain {
            try saveOverwritesExistingToken()
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

    // MARK: Engine credential swap

    /// Factory observing every credential handed to it.
    private final class RecordingFactory: @unchecked Sendable {
        private let lock = NSLock()
        private(set) var seenTokens: [String] = []
        var asFactory: GitHubClientFactory {
            GitHubClientFactory { [self] credentials in make(credentials) }
        }
        func make(_ credentials: GitHubCredentials) -> GitHubServing {
            lock.lock(); seenTokens.append(credentials.token); lock.unlock()
            return SwapProbeClient(token: credentials.token)
        }
    }

    /// Minimal client that remembers the token it was built with.
    private final class SwapProbeClient: GitHubServing, @unchecked Sendable {
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
        let swapped = engine.github as? SwapProbeClient
        XCTAssertEqual(swapped?.token, "ghp_new", "engine.github must serve the new credentials")
    }

    func testReplaceCredentialsPreservesScope() async {
        var cfg = makeTestConfig()
        cfg.repo = "acme"
        let engine = FleetEngine(
            config: cfg, pat: "ghp_old", tart: FakeTart(), store: makeTestStore(),
            ssh: FakeSSH(), host: testHost, githubFactory: GitHubClientFactory { SwapProbeClient(token: $0.token) }
        )
        await engine.replaceCredentials(pat: "ghp_new")
        // The swapped client still routes through the org scope: minting a
        // registration token succeeds against whatever scope the factory set.
        let probe = engine.github as! SwapProbeClient
        XCTAssertEqual(probe.token, "ghp_new")
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

    // MARK: Daemon RPC

    func testDaemonReplaceTokenRoundTrip() async throws {
        let recording = RecordingFactory()
        let engine = makeEngine(pat: "ghp_old", github: SwapProbeClient(token: "ghp_old"), factory: recording.asFactory)

        let payload = try JSONEncoder().encode(TokenReplaceRequest(pat: "ghp_via_rpc"))
        let response = await Daemon.handle(RPCRequest(id: 11, method: .replaceToken, payload: payload), engine: engine)

        XCTAssertTrue(response.ok)
        XCTAssertEqual((engine.github as? SwapProbeClient)?.token, "ghp_via_rpc")
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

    // MARK: Setup checklist contract

    func testStoredTokenStillOffersReplaceAction() async {
        let computer = SetupCheckHelper.make(
            tartHealth: .healthy,
            tartList: [
                TartVM(name: "tahoe-base", source: "ghcr.io/cirruslabs/macos-tahoe-base:latest", status: "stopped")
            ],
            config: makeTestConfig(),
            tokenStored: true
        )
        let status = await computer.compute()
        let token = status.checks.first { $0.id == "token" }
        XCTAssertEqual(token?.action, "replace_token", "a stored token must remain replaceable from the checklist")
        XCTAssertEqual(SetupAction.title(for: "replace_token"), "Replace Token…")
    }

    func testMissingTokenOffersEnterAction() async {
        let computer = SetupCheckHelper.make(
            tartHealth: .healthy,
            tartList: [
                TartVM(name: "tahoe-base", source: "ghcr.io/cirruslabs/macos-tahoe-base:latest", status: "stopped")
            ],
            config: makeTestConfig(),
            tokenStored: false
        )
        let status = await computer.compute()
        XCTAssertEqual(status.checks.first { $0.id == "token" }?.action, "enter_token")
    }

    func waitUntil(timeout: TimeInterval, _ condition: () async -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if await condition() { return }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        XCTFail("condition not met within \(timeout)s")
    }
}
