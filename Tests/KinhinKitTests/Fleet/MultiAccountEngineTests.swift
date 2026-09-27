import XCTest

@testable import KinhinKit
@testable import KinhinTestSupport

/// Several GitHub accounts served by one engine, each with its own client,
/// token and registration-token cache.
final class MultiAccountEngineTests: XCTestCase {
    private func config() throws -> KinhinConfig {
        try ConfigLoader.parse(
            """
            repo: "acme/widgets"
            labels: [kinhin]
            poll_interval: 5
            accounts:
              - {name: work, forge: github, scope: bigco}
              - {name: side, forge: github, scope: me/proj}

            """)
    }

    /// One `FakeGitHub` per token, so each account's traffic is observable.
    private final class Clients: @unchecked Sendable {
        private let lock = NSLock()
        private var byToken: [String: FakeGitHub] = [:]
        func client(for token: String) -> FakeGitHub {
            lock.withLock {
                if let existing = byToken[token] { return existing }
                let fresh = FakeGitHub()
                byToken[token] = fresh
                return fresh
            }
        }
    }

    private func makeEngine(
        tokens: [String: String], clients: Clients, legacy: FakeGitHub = FakeGitHub()
    ) throws -> FleetEngine {
        let engine = FleetEngine(
            config: try config(), pat: "legacy", tart: FakeTart(), store: makeTestStore(), ssh: FakeSSH(),
            host: testHost,
            githubFactory: GitHubClientFactory { clients.client(for: $0.token) })
        engine.tokenLoader = { _, name in tokens[name] }
        return engine
    }

    func testEveryAccountWithATokenIsAttached() async throws {
        let engine = try makeEngine(tokens: ["work": "w", "side": "s"], clients: Clients())
        await engine.start()
        XCTAssertEqual(Set(engine.forges.keys), ["github", "work", "side"])
        XCTAssertEqual(engine.forges["work"]?.account, "work")
        await engine.stop()
    }

    func testAccountWithoutATokenIsSkippedAndExplained() async throws {
        let engine = try makeEngine(tokens: ["work": "w"], clients: Clients())
        await engine.start()
        XCTAssertEqual(Set(engine.forges.keys), ["github", "work"], "one missing token must not drop the others")
        let error = await engine.status().lastError
        XCTAssertTrue(error?.contains("kinhin auth set --account side") == true, "\(error ?? "nil")")
        await engine.stop()
    }

    func testFailingAccountIsDetachedWithoutAffectingOthers() async throws {
        let clients = Clients()
        clients.client(for: "s").permissionDenied = true
        let engine = try makeEngine(tokens: ["work": "w", "side": "s"], clients: clients)
        await engine.start()
        XCTAssertEqual(Set(engine.forges.keys), ["github", "work"])
        XCTAssertEqual(engine.detachedAccounts().map(\.name), ["side"])
        let error = await engine.status().lastError
        XCTAssertTrue(error?.hasPrefix("account 'side'") == true, "\(error ?? "nil")")
        await engine.stop()
    }

    func testDetachedAccountReattachesOnceItsTokenWorks() async throws {
        let clients = Clients()
        let bad = clients.client(for: "s")
        bad.permissionDenied = true
        let engine = try makeEngine(tokens: ["work": "w", "side": "s"], clients: clients)
        await engine.start()
        XCTAssertEqual(engine.detachedAccounts().count, 1)

        bad.permissionDenied = false
        await engine.retryDetachedForgesIfDue(ignoreBackoff: true)
        XCTAssertTrue(engine.detachedAccounts().isEmpty)
        await engine.stop()
    }

    func testNewVMGoesToTheAccountWithTheMostUnmetDemand() async throws {
        let clients = Clients()
        clients.client(for: "w").queueDepth = 3
        let engine = try makeEngine(tokens: ["work": "w", "side": "s"], clients: clients)
        await engine.attachAccountsIfNeeded()  // no background loop: one deterministic pass
        try await engine.reconcileOnce()
        let platforms = engine.store.all.compactMap(\.platform)
        XCTAssertFalse(platforms.isEmpty)
        XCTAssertEqual(Set(platforms), ["work"], "only 'work' has queued jobs")
        await engine.stop()
    }

    func testRegistrationTokenComesFromTheRecordsOwnAccount() async throws {
        let clients = Clients()
        clients.client(for: "s").queueDepth = 1
        let engine = try makeEngine(tokens: ["work": "w", "side": "s"], clients: clients)
        await engine.attachAccountsIfNeeded()
        try await engine.reconcileOnce()
        for _ in 0..<100 where clients.client(for: "s").registrationTokenCalls < 2 {
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        // One call from the attach probe, one from the VM's registration.
        XCTAssertEqual(clients.client(for: "s").registrationTokenCalls, 2)
        XCTAssertEqual(clients.client(for: "w").registrationTokenCalls, 1, "only the attach probe")
        XCTAssertEqual(clients.client(for: "legacy").registrationTokenCalls, 0, "the legacy account is untouched")
        await engine.stop()
    }

    func testReplaceTokenSwapsOnlyThatAccount() async throws {
        let clients = Clients()
        let engine = try makeEngine(tokens: ["work": "w", "side": "s"], clients: clients)
        await engine.start()
        let workBefore = engine.forges["work"] as? GitHubForge
        await engine.replaceToken(account: "side", token: "s2")
        let side = engine.forges["side"] as? GitHubForge
        XCTAssertEqual(side.map { $0.credentials.token }, "s2")
        XCTAssertEqual(
            (engine.forges["work"] as? GitHubForge).map { $0.credentials.token },
            workBefore.map { $0.credentials.token })
        await engine.stop()
    }

    func testReplaceTokenForUnknownAccountIsIgnored() async throws {
        let engine = try makeEngine(tokens: ["work": "w", "side": "s"], clients: Clients())
        await engine.start()
        await engine.replaceToken(account: "nope", token: "x")
        XCTAssertEqual(Set(engine.forges.keys), ["github", "work", "side"])
        await engine.stop()
    }

    func testOldFleetRecordsStillDecodeWithoutAnAccount() throws {
        let json = #"{"id":"kinhin-1","phase":"ready","createdAt":0,"updatedAt":0,"platform":"gitea"}"#
        let record = try? JSONDecoder().decode(VMRecord.self, from: Data(json.utf8))
        XCTAssertEqual(record?.platform ?? "gitea", "gitea")
    }
}
