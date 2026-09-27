import XCTest

@testable import KinhinKit
@testable import KinhinTestSupport

/// A config with a `gitea:` section and the starter placeholder repo serves
/// Gitea only: no GitHub token, no GitHub verification.
final class GiteaOnlyTests: XCTestCase {
    private func giteaOnlyConfig() throws -> KinhinConfig {
        try ConfigLoader.parse(
            """
            repo: "\(ConfigLoader.templateRepo)"
            labels: [self-hosted, macOS]
            gitea:
              instance: "https://git.example.com"
              scope: "team/repo"
            """)
    }

    func testGiteaOnlyConfigIsUsableWithoutGitHub() throws {
        let cfg = try giteaOnlyConfig()
        XCTAssertFalse(cfg.githubEnabled)
        XCTAssertTrue(ConfigLoader.hasAnyForge(cfg))
    }

    func testTemplateWithoutGiteaIsNotUsable() throws {
        let cfg = try ConfigLoader.parse("repo: \"\(ConfigLoader.templateRepo)\"\nlabels: [a]\n")
        XCTAssertFalse(ConfigLoader.hasAnyForge(cfg))
        XCTAssertNil(try ConfigLoader.engineToken(for: cfg, load: { _ in "tok" }))
    }

    func testEngineTokenRequiresTheRightForgeToken() throws {
        let gitea = try giteaOnlyConfig()
        XCTAssertEqual(
            try ConfigLoader.engineToken(for: gitea, load: { $0 == .gitea ? "gt" : nil }), "",
            "Gitea-only needs only the Gitea token; the GitHub slot is an empty placeholder")
        XCTAssertNil(
            try ConfigLoader.engineToken(for: gitea, load: { $0 == .github ? "gh" : nil }),
            "a GitHub token does not satisfy a Gitea-only config")

        let github = try ConfigLoader.parse("repo: \"acme/widgets\"\nlabels: [a]\n")
        XCTAssertEqual(try ConfigLoader.engineToken(for: github, load: { $0 == .github ? "gh" : nil }), "gh")
        XCTAssertNil(try ConfigLoader.engineToken(for: github, load: { _ in nil }))
    }

    func testEngineStartSkipsGitHubVerificationWhenGiteaOnly() async throws {
        let github = FakeGitHub()
        github.permissionDenied = true  // would block startup if GitHub were probed
        let engine = FleetEngine(
            config: try giteaOnlyConfig(),
            github: github,
            tart: FakeTart(),
            store: makeTestStore(),
            ssh: FakeSSH(),
            host: testHost
        )
        await engine.start()
        XCTAssertEqual(github.registrationTokenCalls, 0, "GitHub is never contacted in a Gitea-only fleet")
        let status = await engine.status()
        XCTAssertNil(status.lastError.flatMap { $0.contains("PAT") ? $0 : nil }, "no GitHub permission error surfaces")
        await engine.stop()
    }
}

final class GiteaOnlyCLITests: XCTestCase {
    private let giteaOnly = try! ConfigLoader.parse(
        """
        repo: "\(ConfigLoader.templateRepo)"
        labels: [a]
        gitea:
          instance: "https://git.example.com"
          scope: "team/repo"
        """)

    func testAuthStatusIsGoodWithOnlyTheGiteaToken() {
        let report = AuthStatusReporter.report(config: giteaOnly, load: { $0 == .gitea ? "gt-token" : nil })
        XCTAssertTrue(report.allGood, "a Gitea-only config needs no GitHub token")
        XCTAssertFalse(report.forges.first { $0.id == "github" }!.configured)
    }

    func testAuthStatusNotGoodWithoutTheGiteaToken() {
        let report = AuthStatusReporter.report(config: giteaOnly, load: { $0 == .github ? "gh" : nil })
        XCTAssertFalse(report.allGood)
    }

    func testSetupChecklistHasNoGitHubRowForGiteaOnly() async {
        let status = await SetupStatusComputer(
            clt: .ok(version: "15"), tartHealth: .healthy, config: .loaded(giteaOnly),
            tokenStored: false, giteaTokenStored: true
        ).compute()
        XCTAssertNil(status.checks.first { $0.id == "token" })
        XCTAssertEqual(status.checks.first { $0.id == "gitea-token" }?.ok, true)
        XCTAssertEqual(status.checks.first { $0.id == "config" }?.ok, true)
    }
}

/// GitHub and Gitea served by one engine at the same time.
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
            repo: "acme/widgets"
            labels: [self-hosted, macOS]
            gitea:
              instance: "https://git.example.com"
              scope: "team/repo"
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
            status.lastError?.hasPrefix("GitHub:") ?? false, "the reason stays visible: \(status.lastError ?? "nil")")
        await engine.stop()
    }

    func testFleetStillRefusesToStartWhenNoForgeWorks() async throws {
        let github = FakeGitHub()
        github.permissionDenied = true
        let engine = FleetEngine(
            config: try ConfigLoader.parse("repo: \"acme/widgets\"\nlabels: [a]\n"), github: github,
            tart: FakeTart(), store: makeTestStore(), ssh: FakeSSH(), host: testHost)
        await engine.start()
        let status = await engine.status()
        XCTAssertFalse(status.running)
        XCTAssertNotNil(status.lastError)
    }

    func testEngineTokenAllowsGiteaWhenTheGitHubTokenIsMissing() throws {
        let cfg = try bothConfig()
        XCTAssertEqual(try ConfigLoader.engineToken(for: cfg, load: { $0 == .gitea ? "gt" : nil }), "")
        XCTAssertEqual(try ConfigLoader.engineToken(for: cfg, load: { $0 == .github ? "gh" : nil }), "gh")
        XCTAssertNil(try ConfigLoader.engineToken(for: cfg, load: { _ in nil }))
    }
}

/// Forges dropped at startup come back on their own.
final class ForgeRetryTests: XCTestCase {
    private func makeDual(github: FakeGitHub) throws -> FleetEngine {
        let cfg = try ConfigLoader.parse(
            """
            repo: "acme/widgets"
            labels: [a]
            gitea:
              instance: "https://git.example.com"
              scope: "team/repo"
            """)
        let engine = FleetEngine(
            config: cfg, github: github, tart: FakeTart(),
            store: makeTestStore(), ssh: FakeSSH(), host: testHost)
        engine.forgeState.withLock { $0.byPlatform["gitea"] = DualForgeTests.FakeGitea() }
        return engine
    }

    func testGitHubReattachesOnceItRecovers() async throws {
        let github = FakeGitHub()
        github.permissionDenied = true
        let engine = try makeDual(github: github)
        await engine.start()
        XCTAssertNil(engine.forges["github"], "dropped at startup")

        // Still broken: retry keeps it detached and keeps the reason visible.
        await engine.retryDetachedForgesIfDue(ignoreBackoff: true)
        XCTAssertNil(engine.forges["github"])
        let stillBroken = await engine.status().lastError
        XCTAssertTrue(stillBroken?.hasPrefix("GitHub:") ?? false)

        // Recovered: the next retry re-attaches it and clears the error.
        github.permissionDenied = false
        await engine.retryDetachedForgesIfDue(ignoreBackoff: true)
        XCTAssertNotNil(engine.forges["github"], "GitHub is serving again without a restart")
        let cleared = await engine.status().lastError
        XCTAssertNil(cleared)
        await engine.stop()
    }

    func testRetryRespectsBackoff() async throws {
        let github = FakeGitHub()
        github.permissionDenied = true
        let engine = try makeDual(github: github)
        await engine.start()
        let callsAfterStart = github.registrationTokenCalls

        github.permissionDenied = false
        await engine.retryDetachedForgesIfDue(now: Date())  // too soon
        XCTAssertEqual(github.registrationTokenCalls, callsAfterStart, "no probe before the backoff elapses")
        XCTAssertNil(engine.forges["github"])

        await engine.retryDetachedForgesIfDue(now: Date().addingTimeInterval(31))
        XCTAssertNotNil(engine.forges["github"], "after 30s the retry runs")
        await engine.stop()
    }

    func testBackoffDoublesAndCaps() {
        var state = ForgeRetryState()
        let now = Date()
        state.markGitHubDetached(now: now)
        XCTAssertEqual(state.delay, 30)
        for expected in [60.0, 120, 240, 300, 300] {
            state.backOff(now: now)
            XCTAssertEqual(state.delay, expected)
        }
    }

    func testNothingRetriesWhenAllForgesAreAttached() async throws {
        let github = FakeGitHub()
        let engine = try makeDual(github: github)
        await engine.start()
        let calls = github.registrationTokenCalls
        await engine.retryDetachedForgesIfDue(ignoreBackoff: true)
        XCTAssertEqual(github.registrationTokenCalls, calls)
        await engine.stop()
    }
}

/// Tart is optional when a Linux runtime is configured.
final class LinuxOnlyTests: XCTestCase {
    private let linux = try! ConfigLoader.parse(
        """
        repo: "acme/widgets"
        labels: [a]
        docker:
          image: "kinhin-ci-linux"
        """)
    private let macOnly = try! ConfigLoader.parse("repo: \"acme/widgets\"\nlabels: [a]\n")

    func testHasLinuxRuntime() {
        XCTAssertTrue(linux.hasLinuxRuntime)
        XCTAssertFalse(macOnly.hasLinuxRuntime)
    }

    func testLinuxOnlyEngineRunsWithoutTart() async throws {
        let engine = FleetEngine(
            config: linux, github: FakeGitHub(), tart: UnavailableTart(),
            store: makeTestStore(), ssh: FakeSSH(), host: testHost)
        await engine.start()
        // The engine starts; nothing throws for the missing tart.
        try await engine.reconcileOnce()
        await engine.stop()
    }

    func testUnavailableTartFailsClearlyAndListsNothing() async {
        let tart = UnavailableTart()
        let vms = try? await tart.list()
        XCTAssertEqual(vms?.count, 0, "recovery finds no tart VMs")
        do { try await tart.clone(source: "a", to: "b"); XCTFail() } catch {
            XCTAssertTrue(error.localizedDescription.contains("tart not found"))
        }
    }

    func testChecklistIsReadyWithoutTartWhenDockerIsConfigured() async {
        let status = await SetupStatusComputer(
            clt: .ok(version: "15"), tartHealth: .missing, config: .loaded(linux),
            tokenStored: true, dockerHealth: .ready, dockerImages: ["kinhin-ci-linux"]
        ).compute()
        XCTAssertFalse(status.checks.first { $0.id == "tart" }!.ok, "tart itself is still reported as missing")
        XCTAssertTrue(
            status.ready, "but it no longer blocks a Linux-only fleet: \(status.checks.filter { !$0.ok }.map(\.id))")
    }

    func testChecklistStillNeedsTartForAMacOnlyConfig() async {
        let status = await SetupStatusComputer(
            clt: .ok(version: "15"), tartHealth: .missing, config: .loaded(macOnly), tokenStored: true
        ).compute()
        XCTAssertFalse(status.ready)
    }
}
