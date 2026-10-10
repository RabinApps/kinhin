import Synchronization
import XCTest

@testable import KinhinKit
@testable import KinhinTestSupport

final class RunnerDirectoryTests: XCTestCase {
    /// A clock the test advances by hand.
    private final class ManualClock: Sendable {
        private let offset = Mutex(Duration.zero)
        private let origin = ContinuousClock.now
        func now() -> ContinuousClock.Instant { origin + offset.withLock { $0 } }
        func advance(_ by: Duration) { offset.withLock { $0 += by } }
    }

    private func makeForge(_ github: FakeGitHub) -> GitHubForge {
        GitHubForge(
            credentials: .github(token: "t", scope: "acme/widgets"), labels: ["kinhin"], client: github,
            account: "github")
    }

    func testReadsWithinTheTTLShareOneCall() async throws {
        let github = FakeGitHub()
        let clock = ManualClock()
        let directory = RunnerDirectory(ttl: .seconds(5), now: { clock.now() })
        let forge = makeForge(github)

        for _ in 0..<20 { _ = try await directory.runners(of: forge) }

        XCTAssertEqual(github.listRunnersCallCount, 1)
    }

    func testAnExpiredEntryIsRefetched() async throws {
        let github = FakeGitHub()
        let clock = ManualClock()
        let directory = RunnerDirectory(ttl: .seconds(5), now: { clock.now() })
        let forge = makeForge(github)

        _ = try await directory.runners(of: forge)
        clock.advance(.seconds(6))
        _ = try await directory.runners(of: forge)

        XCTAssertEqual(github.listRunnersCallCount, 2)
    }

    func testCachedReadIsStaleByDesignAndFreshReadIsNot() async throws {
        let github = FakeGitHub()
        let clock = ManualClock()
        let directory = RunnerDirectory(ttl: .seconds(5), now: { clock.now() })
        let forge = makeForge(github)
        github.register(name: "kinhin-a", busy: false)
        let first = try await directory.runners(of: forge)
        XCTAssertEqual(first.map(\.name), ["kinhin-a"])

        github.deregister(name: "kinhin-a")
        let cached = try await directory.runners(of: forge)
        XCTAssertEqual(cached.map(\.name), ["kinhin-a"], "inside the TTL the old list is served")

        let fresh = try await directory.freshRunners(of: forge)
        XCTAssertTrue(fresh.isEmpty, "a fresh read asks the forge")
        let afterwards = try await directory.runners(of: forge)
        XCTAssertTrue(afterwards.isEmpty, "and refreshes what the watchers see")
    }

    /// GitLab keeps its own 3 s list behind `runners()`; a fresh read must get
    /// past it too, or "the runner is gone" is decided on a stale list.
    func testFreshReadGetsPastTheForgesOwnListCache() async throws {
        let server = FakeGitLabServer()
        StubProtocol.handler = { server.handle($0) }
        defer { StubProtocol.handler = nil }
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubProtocol.self]
        let forge = GitLabForge(
            credentials: .gitlab(token: "glpat", scope: "acme/api", instance: GitLabCredentials.defaultInstance),
            labels: ["macos"],
            client: GitLabClient(
                credentials: GitLabCredentials(token: "glpat", scope: "acme/api"),
                session: URLSession(configuration: config)),
            scope: .project(id: 7, path: "acme/api"), runnerListTTL: 60)
        _ = try await forge.registrationTokens(runnerNames: ["kinhin-1"], labels: [])
        let directory = RunnerDirectory(ttl: .seconds(0))

        let listed = try await directory.runners(of: forge)
        XCTAssertEqual(listed.map(\.name), ["kinhin-1"])
        server.deleteRunner(named: "kinhin-1")
        let stale = try await directory.runners(of: forge)
        XCTAssertEqual(stale.map(\.name), ["kinhin-1"], "the forge's snapshot is still inside its TTL")

        let fresh = try await directory.freshRunners(of: forge)
        XCTAssertTrue(fresh.isEmpty)
    }

    func testAccountsAreCachedSeparately() async throws {
        let github = FakeGitHub()
        let other = FakeGitHub()
        let directory = RunnerDirectory(ttl: .seconds(5))
        let forge = makeForge(github)
        let second = GitHubForge(
            credentials: .github(token: "t", scope: "acme/other"), labels: ["kinhin"], client: other, account: "other")

        _ = try await directory.runners(of: forge)
        _ = try await directory.runners(of: second)

        XCTAssertEqual(github.listRunnersCallCount, 1)
        XCTAssertEqual(other.listRunnersCallCount, 1)
    }

    func testAFailedReadIsNotCached() async throws {
        let github = FakeGitHub()
        let directory = RunnerDirectory(ttl: .seconds(5))
        let forge = makeForge(github)
        github.failRunnerList = true
        do {
            _ = try await directory.runners(of: forge)
            XCTFail("the failure must reach the caller")
        } catch {}

        github.failRunnerList = false
        github.register(name: "kinhin-a", busy: false)
        let runners = try await directory.runners(of: forge)
        XCTAssertEqual(runners.map(\.name), ["kinhin-a"])
    }

    /// The point of the directory: many watchers, few API calls.
    func testManyWatchersCostFewRunnerListCalls() async throws {
        var cfg = makeTestConfig()
        cfg.maxRunners = 3
        let github = FakeGitHub()
        github.queueDepth = 3
        let engine = FleetEngine(
            config: cfg, github: github, tart: FakeTart(), store: makeTestStore(), ssh: FakeSSH(),
            host: HostResources(logicalCores: 64, memoryGB: 256, freeDiskGB: 2000, arm64: true),
            dependencies: .init(
                tokenLoader: { _, _ in "t" }, spawnStagger: .zero, exitWatchInterval: .milliseconds(20),
                runnerCacheTTL: .milliseconds(250)))
        try await engine.reconcileOnce()
        try await waitUntil(timeout: 10) { engine.store.all.filter { $0.phase == .ready }.count == 3 }
        let before = github.listRunnersCallCount

        try await Task.sleep(for: .seconds(1))

        let calls = github.listRunnersCallCount - before
        // Per-watcher polling would be 3 watchers × ~50 polls.
        XCTAssertLessThan(calls, 30, "\(calls) runner-list calls in one second for three watchers")
        await engine.stop()
    }
}
