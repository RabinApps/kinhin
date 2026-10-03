import Synchronization
import XCTest

@testable import KinhinKit
@testable import KinhinTestSupport

/// Counts `processSamples` calls (and can park them) behind an otherwise inert tart.
private final class CountingTart: TartControlling, Sendable {
    private let state = Mutex((calls: 0, release: true))
    var calls: Int { state.withLock { $0.calls } }
    func hold() { state.withLock { $0.release = false } }
    func release() { state.withLock { $0.release = true } }

    func processSamples(of names: [String]) async throws -> [String: ProcessSample] {
        state.withLock { $0.calls += 1 }
        while !state.withLock({ $0.release }) { try await Task.sleep(for: .milliseconds(5)) }
        return Dictionary(uniqueKeysWithValues: names.map { ($0, ProcessSample(rssMB: 512, cpuSeconds: 1)) })
    }

    func list() async throws -> [TartVM] { [] }
    func clone(source: String, to name: String) async throws {}
    func run(name: String, mounts: [String]) async throws {}
    func ip(of name: String, timeout: TimeInterval) async throws -> String { "" }
    func stop(name: String) async throws {}
    func delete(name: String) async throws {}
    func pull(image: String) async throws {}
    func createLinux(name: String) async throws {}
    func runWithDisk(name: String, isoPath: String) async throws {}
}

final class UsageSamplerTests: XCTestCase {
    private func makeSampler(_ tart: CountingTart, minInterval: Duration = .milliseconds(0)) -> UsageSampler {
        UsageSampler(
            tart: tart, shell: FakeShell(), tartMemoryMB: { 4096 }, minInterval: minInterval, maxStale: .seconds(30))
    }

    private let records = [VMRecord(id: "kinhin-1", phase: .ready, createdAt: Date())]

    func testConcurrentCallersShareOneSample() async {
        let tart = CountingTart()
        tart.hold()
        let sampler = makeSampler(tart)
        let records = records
        async let first = sampler.snapshot(for: records)
        async let second = sampler.snapshot(for: records)
        async let third = sampler.snapshot(for: records)
        try? await Task.sleep(for: .milliseconds(100))
        tart.release()
        let snapshots = await [first, second, third]
        XCTAssertEqual(tart.calls, 1, "one sample for all concurrent callers")
        XCTAssertTrue(snapshots.allSatisfy { $0.byInstance["kinhin-1"]?.memoryUsedMB == 512 })
    }

    func testAStaleSnapshotIsServedImmediatelyWhileItRefreshes() async throws {
        let tart = CountingTart()
        let sampler = makeSampler(tart)
        _ = await sampler.snapshot(for: records)  // warm
        XCTAssertEqual(tart.calls, 1)

        tart.hold()  // the refresh will park
        let started = ContinuousClock.now
        let stale = await sampler.snapshot(for: records)
        XCTAssertLessThan(ContinuousClock.now - started, .milliseconds(500), "did not wait for the refresh")
        XCTAssertNotNil(stale.byInstance["kinhin-1"])
        try await waitUntil { tart.calls == 2 }
        tart.release()
    }

    func testAFreshSnapshotCostsNoSample() async {
        let tart = CountingTart()
        let sampler = makeSampler(tart, minInterval: .seconds(60))
        _ = await sampler.snapshot(for: records)
        _ = await sampler.snapshot(for: records)
        XCTAssertEqual(tart.calls, 1)
    }

    func testStatusWithoutUsageSkipsSampling() async throws {
        let tart = FakeTart()
        let engine = FleetEngine(
            config: makeTestConfig(), github: FakeGitHub(), tart: tart, store: makeTestStore(), ssh: FakeSSH(),
            host: testHost)
        let status = await engine.status(includeUsage: false)
        XCTAssertNil(status.host, "no host sample when usage is not wanted")
        let full = await engine.status()
        XCTAssertNotNil(full.host)
    }

    func testStatusRequestPayloadIsBackwardCompatible() async throws {
        let engine = FleetEngine(
            config: makeTestConfig(), github: FakeGitHub(), tart: FakeTart(), store: makeTestStore(),
            ssh: FakeSSH(), host: testHost)
        // No payload: the full status, as older clients ask.
        let plain = await Daemon.handle(RPCRequest(id: 1, method: .status), engine: engine)
        XCTAssertTrue(plain.ok)
        let lean = await Daemon.handle(
            RPCRequest(
                id: 2, method: .status, payload: try JSONEncoder().encode(Daemon.StatusRequest(includeUsage: false))),
            engine: engine)
        XCTAssertTrue(lean.ok)
        let leanStatus = try JSONDecoder().decode(FleetStatus.self, from: try XCTUnwrap(lean.payload))
        XCTAssertNil(leanStatus.host)
    }
}
