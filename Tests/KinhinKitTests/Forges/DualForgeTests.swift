import XCTest

@testable import KinhinKit
@testable import KinhinTestSupport

final class DualForgeTests: XCTestCase {
    struct FakeGitea: Forge {
        var id: ForgeID { .gitea }
        var name: String { "gitea" }
        var credentials: ForgeCredentials {
            .gitea(token: "t", scope: "team/repo", instance: "https://git.example.com")
        }
        var labels: [String] { ["macos:host"] }
        var registration: ForgeRegistration { .sharedLongLived }
        var exitSemantics: ForgeExitSemantics { .idleGrace }
        func registrationURL() -> String { "https://git.example.com" }
        func mintRegistrationToken() async throws -> String { "rt" }
        func runners() async throws -> [ForgeRunner] { [] }
        func deleteRunner(id: Int) async throws {}
        func queuedJobs() async throws -> [ForgeJob] { [] }
        func runningJobs() async throws -> [ForgeJob] { [] }
    }

    private func bothConfig() throws -> KinhinConfig {
        try ConfigLoader.parse(
            """
            accounts:
              - name: github
                forge: github
                scope: "acme/widgets"
              - name: gitea
                forge: gitea
                scope: "team/repo"
                instance: "https://git.example.com"
            labels: [self-hosted, macOS]
            """)
    }

    private func engine(github: FakeGitHub) throws -> FleetEngine {
        let engine = FleetEngine(
            config: try bothConfig(), github: github, tart: FakeTart(),
            store: makeTestStore(), ssh: FakeSSH(), host: testHost)
        // Pre-attached: the engine skips building a real Gitea client.
        engine.forgeState.withLock { $0.byPlatform["gitea"] = FakeGitea() }
        return engine
    }

    /// The status snapshot's `running` flag is written by the reconcile loop's
    /// first pass, so wait for it instead of reading it immediately.
    private func waitUntilRunning(_ engine: FleetEngine) async -> FleetStatus {
        for _ in 0..<100 {
            let status = await engine.status()
            if status.running { return status }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        return await engine.status()
    }

    func testBothForgesRunTogether() async throws {
        let github = FakeGitHub()
        let engine = try engine(github: github)
        await engine.start()
        let forges = Set(engine.forges.keys)
        XCTAssertEqual(forges, ["github", "gitea"])
        let status = await waitUntilRunning(engine)
        XCTAssertTrue(status.running)
        await engine.stop()
    }

    func testGitHubFailureDoesNotStopGitea() async throws {
        let github = FakeGitHub()
        github.permissionDenied = true
        let engine = try engine(github: github)
        await engine.start()
        let forges = Set(engine.forges.keys)
        XCTAssertEqual(forges, ["gitea"], "the failing forge is detached, the healthy one keeps serving")
        let status = await waitUntilRunning(engine)
        XCTAssertTrue(status.running, "the fleet still starts on Gitea")
        XCTAssertTrue(
            status.lastError?.hasPrefix("account 'github':") ?? false,
            "the reason stays visible: \(status.lastError ?? "nil")")
        await engine.stop()
    }

    func testFleetStillRefusesToStartWhenNoForgeWorks() async throws {
        let github = FakeGitHub()
        github.permissionDenied = true
        let engine = FleetEngine(
            config: try ConfigLoader.parse(
                "accounts:\n  - name: github\n    forge: github\n    scope: \"acme/widgets\"\nlabels: [a]\n"),
            github: github,
            tart: FakeTart(), store: makeTestStore(), ssh: FakeSSH(), host: testHost)
        await engine.start()
        let status = await engine.status()
        XCTAssertFalse(status.running)
        XCTAssertNotNil(status.lastError)
    }

    func testEngineTokenAllowsGiteaWhenTheGitHubTokenIsMissing() throws {
        let cfg = try bothConfig()
        XCTAssertEqual(
            try ConfigLoader.engineToken(
                for: cfg, loadAccount: { forge, _ in forge == .gitea ? "gt" : nil }),
            "", "the Gitea token makes the dual fleet usable even without the GitHub token")
        XCTAssertNil(
            try ConfigLoader.engineToken(for: cfg, loadAccount: { _, _ in nil }),
            "no tokens at all → the fleet cannot run")
    }
}

/// Forges dropped at startup come back on their own.
