import XCTest

@testable import KinhinKit
@testable import KinhinTestSupport

/// Busy instances versus queued demand, through the real reconcile pass.
/// Classic forges report queued-only jobs, so a busy VM (whose job already
/// left the queue) must not satisfy a queued job.
final class BusyDemandTests: XCTestCase {
    private let bigHost = HostResources(logicalCores: 64, memoryGB: 256, freeDiskGB: 2000, arm64: true)

    private func makeEngine(github: FakeGitHub) -> FleetEngine {
        var cfg = makeTestConfig()
        cfg.maxRunners = 4
        let engine = FleetEngine(
            config: cfg, github: github, tart: FakeTart(),
            store: makeTestStore(), ssh: FakeSSH(), host: bigHost
        )
        return engine
    }

    private func seed(_ engine: FleetEngine, phase: VMPhase, count: Int) {
        for index in 0..<count {
            var record = VMRecord(id: "kinhin-seed-\(phase.rawValue)-\(index)", phase: phase)
            record.platform = "github"
            record.runtimeID = .tart
            engine.store.upsert(record)
        }
    }

    func testBusyVMsDoNotSatisfyQueuedJobs() async throws {
        let github = FakeGitHub()
        let engine = makeEngine(github: github)
        XCTAssertGreaterThanOrEqual(engine.capacity.maxConcurrent, 4, "the fixture host must hold four VMs")
        seed(engine, phase: .busy, count: 2)
        github.queueDepth = 2

        try await engine.reconcileOnce()

        let active = engine.store.all.filter { $0.phase.isActive }
        XCTAssertEqual(active.count, 4, "two busy VMs plus one new VM per queued job")
        XCTAssertEqual(active.filter { $0.phase == .busy }.count, 2)
        await engine.stop()
    }

    func testReadyVMStillCoversAQueuedJob() async throws {
        let github = FakeGitHub()
        let engine = makeEngine(github: github)
        seed(engine, phase: .busy, count: 1)
        seed(engine, phase: .ready, count: 1)
        github.queueDepth = 1

        try await engine.reconcileOnce()

        XCTAssertEqual(engine.store.all.filter { $0.phase.isActive }.count, 2, "the ready VM takes the queued job")
        await engine.stop()
    }

    func testBusyVMsNeverPushPastTheCap() async throws {
        let github = FakeGitHub()
        let engine = makeEngine(github: github)
        seed(engine, phase: .busy, count: 3)
        github.queueDepth = 5

        try await engine.reconcileOnce()

        XCTAssertEqual(engine.store.all.filter { $0.phase.isActive }.count, 4, "max_runners still binds")
        await engine.stop()
    }
}
