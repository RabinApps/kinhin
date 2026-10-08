import XCTest

@testable import KinhinKit
@testable import KinhinTestSupport

/// How the engine feeds the spawn backoff: failures that never reach a
/// `.failed` record still count, and success means a runner came online.
final class SpawnBackoffEngineTests: XCTestCase {
    private func makeEngine(github: FakeGitHub, maxRunners: Int = 1) -> FleetEngine {
        var cfg = makeTestConfig()
        cfg.maxRunners = maxRunners
        cfg.vmBootTimeout = 0
        return FleetEngine(
            config: cfg, github: github, tart: FakeTart(), store: makeTestStore(), ssh: FakeSSH(),
            host: HostResources(logicalCores: 64, memoryGB: 256, freeDiskGB: 2000, arm64: true),
            dependencies: .init(
                tokenLoader: { _, _ in "t" }, spawnStagger: .zero, exitWatchInterval: .milliseconds(20),
                watchdog: Watchdog(registrationGrace: .milliseconds(150))))
    }

    func testRegistrationTimeoutsCountTowardTheBackoff() async throws {
        let github = FakeGitHub()
        github.queueDepth = 2
        let engine = makeEngine(github: github, maxRunners: 2)

        try await engine.reconcileOnce()  // two instances whose runners never appear

        try await waitUntil(timeout: 10) {
            engine.spawnBackoff.withLock { $0.blocked(now: Date()) }.contains(.tart)
        }
        await engine.stop()
    }

    func testSuccessWaitsForTheRunnerToComeOnline() async throws {
        let github = FakeGitHub()
        github.queueDepth = 1
        var cfg = makeTestConfig()
        cfg.maxRunners = 1
        // Default registration grace: the watch only waits for the runner here.
        let engine = FleetEngine(
            config: cfg, github: github, tart: FakeTart(), store: makeTestStore(), ssh: FakeSSH(),
            host: HostResources(logicalCores: 64, memoryGB: 256, freeDiskGB: 2000, arm64: true),
            dependencies: .init(tokenLoader: { _, _ in "t" }, spawnStagger: .zero, exitWatchInterval: .milliseconds(20))
        )
        engine.spawnBackoff.withLock { _ = $0.recordFailure(.tart, reason: "earlier", now: Date()) }

        try await engine.reconcileOnce()
        try await waitUntil(timeout: 10) { engine.store.all.first?.phase == .ready }
        // The registration script finished, but no runner is on the forge yet.
        XCTAssertEqual(
            engine.spawnBackoff.withLock { $0.entries[.tart]?.failures }, 1,
            "the script exiting 0 is not proof the runner works")

        let vm = try XCTUnwrap(engine.store.all.first?.id)
        github.register(name: vm, busy: false)
        try await waitUntil(timeout: 10) { engine.spawnBackoff.withLock { $0.entries[.tart] } == nil }
        await engine.stop()
    }
}
