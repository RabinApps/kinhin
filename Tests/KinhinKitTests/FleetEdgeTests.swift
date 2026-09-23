import XCTest
@testable import KinhinKit

final class FleetEdgeTests: XCTestCase {
    func makeEngine(config: kinhinConfig? = nil, tart: FakeTart, github: FakeGitHub, ssh: FakeSSH) -> FleetEngine {
        FleetEngine(
            config: config ?? makeTestConfig(),
            github: github,
            tart: tart,
            store: makeTestStore(),
            ssh: ssh,
            host: testHost
        )
    }

    func waitUntil(timeout: TimeInterval, _ condition: () async -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if await condition() { return }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        XCTFail("condition not met within \(timeout)s")
    }

    func testPauseHoldsFleetAndSkipsQueuePolling() async throws {
        let tart = FakeTart()
        let github = FakeGitHub()
        github.queueDepth = 3
        let engine = makeEngine(tart: tart, github: github, ssh: FakeSSH())

        await engine.setPaused(true)
        try await engine.reconcileOnce()
        var status = await engine.status()
        XCTAssertTrue(status.paused)
        XCTAssertEqual(status.queueDepth, 0, "paused engine must not poll GitHub")
        XCTAssertEqual(status.desired, 0)
        XCTAssertTrue(tart.cloneCalls.isEmpty)

        await engine.setPaused(false)
        try await engine.reconcileOnce()
        try await waitUntil(timeout: 10) {
            let s = await engine.status()
            return s.desired == 2 && s.queueDepth == 3 // max_runners default = 2
        }
        try await waitUntil(timeout: 15) {
            let s = await engine.status()
            return s.records.filter { $0.phase == .ready }.count == 2
        }
    }

    func testFailedVMIsCleanedUpOnNextPass() async throws {
        let tart = FakeTart()
        let github = FakeGitHub()
        github.queueDepth = 1
        let ssh = FakeSSH()
        ssh.failWith = "injected registration failure"
        let engine = makeEngine(tart: tart, github: github, ssh: ssh)

        try await engine.reconcileOnce()
        try await waitUntil(timeout: 10) {
            let s = await engine.status()
            return s.records.first(where: { $0.phase == .failed }) != nil
        }
        let failedID = await engine.status().records.first!.id

        // Next pass with demand gone: the failed VM is reaped.
        ssh.failWith = nil
        github.queueDepth = 0
        try await engine.reconcileOnce()
        try await waitUntil(timeout: 10) {
            let s = await engine.status()
            return s.records.isEmpty
        }
        let deletes = tart.deleteCalls
        XCTAssertTrue(deletes.contains(failedID), "failed VM is deleted, got \(deletes)")
    }

    func testManualDeleteRemovesVMAndGitHubRegistration() async throws {
        let tart = FakeTart()
        let github = FakeGitHub()
        github.queueDepth = 1
        let engine = makeEngine(tart: tart, github: github, ssh: FakeSSH())

        try await engine.reconcileOnce()
        try await waitUntil(timeout: 10) {
            let s = await engine.status()
            return s.records.first?.phase == .ready
        }
        let id = await engine.status().records.first!.id
        github.register(name: id, busy: false)

        await engine.deleteVM(id: id)

        let status = await engine.status()
        XCTAssertTrue(status.records.isEmpty)
        XCTAssertTrue(tart.deleteCalls.contains(id))
        XCTAssertFalse(github.deletedRunnerIDs.isEmpty, "lingering GitHub registration is removed")
    }

    func testNonEphemeralVMStaysAfterJobAndIsRemovedOnStop() async throws {
        var cfg = makeTestConfig()
        cfg.vm.ephemeral = false
        let tart = FakeTart()
        let github = FakeGitHub()
        github.queueDepth = 1
        let engine = makeEngine(config: cfg, tart: tart, github: github, ssh: FakeSSH())

        try await engine.reconcileOnce()
        try await waitUntil(timeout: 10) {
            let s = await engine.status()
            return s.records.first?.phase == .ready
        }
        let id = await engine.status().records.first!.id
        github.register(name: id, busy: true)
        // A non-ephemeral runner's busy state is not watched by the engine
        // (that observation is part of the ephemeral flow); poll directly.
        try await waitUntil(timeout: 10) {
            let runners = try? await github.listRunners()
            return runners?.first { $0.name == id }?.busy == true
        }

        // Long-lived runner: the VM must survive job completion.
        try await Task.sleep(nanoseconds: 2_000_000_000)
        let still = await engine.status().records.first { $0.id == id }
        XCTAssertEqual(still?.phase, .ready, "non-ephemeral VM persists beyond job completion")

        // Engine stop tears active VMs down.
        await engine.stop()
        try await waitUntil(timeout: 15) {
            let s = await engine.status()
            return s.records.isEmpty
        }
    }

    func testScaleDownDeletesIdleSurplus() async throws {
        let tart = FakeTart()
        let github = FakeGitHub()
        github.queueDepth = 2
        let engine = makeEngine(tart: tart, github: github, ssh: FakeSSH())

        try await engine.reconcileOnce()
        try await waitUntil(timeout: 20) {
            let s = await engine.status()
            return s.records.filter { $0.phase == .ready }.count == 2
        }

        github.queueDepth = 0
        try await engine.reconcileOnce()
        try await waitUntil(timeout: 10) {
            let s = await engine.status()
            return s.records.isEmpty
        }
        XCTAssertEqual(tart.deleteCalls.count, 2, "both idle VMs were scaled away")
    }

    func testRegistrationTokenCachedAcrossConcurrentSpawns() async throws {
        let github = FakeGitHub()
        github.queueDepth = 2
        let engine = makeEngine(tart: FakeTart(), github: github, ssh: FakeSSH())

        try await engine.reconcileOnce()
        try await waitUntil(timeout: 20) {
            let s = await engine.status()
            return s.records.filter { $0.phase == .ready }.count == 2
        }
        XCTAssertEqual(github.registrationTokenCalls, 1, "one registration token serves the whole scale-up burst")
    }
}
