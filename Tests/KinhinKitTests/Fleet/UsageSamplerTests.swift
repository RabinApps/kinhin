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

    /// Apple reports a cumulative `cpuUsageUsec`, never a rate: the sampler
    /// must turn the delta between polls into a live percentage.
    func testAppleContainerCPURisesFromItsCumulativeCounter() async throws {
        let shell = FakeShell()
        func stats(_ usec: Int) -> ShellResult {
            ShellResult(
                exitCode: 0,
                stdout:
                    #"[{"id":"kinhin-c","memoryUsageBytes":1073741824,"memoryLimitBytes":4294967296,"cpuUsageUsec":\#(usec)}]"#,
                stderr: "")
        }
        shell.responses = [stats(1_000_000), stats(4_000_000)]
        // maxStale 0: every snapshot waits for its own sample, so the
        // second one carries the counter delta (a non-zero maxStale would
        // serve the previous snapshot while refreshing in the background).
        let sampler = UsageSampler(
            tart: CountingTart(), shell: shell, tartMemoryMB: { 4096 },
            minInterval: .milliseconds(0), maxStale: .milliseconds(0),
            makeContainer: { ContainerManager(tool: $0, shell: $1, binary: "/usr/bin/container") })
        var record = VMRecord(id: "kinhin-c", phase: .ready, createdAt: Date())
        record.runtime = RuntimeID.appleContainer.rawValue

        let first = await sampler.snapshot(for: [record])
        XCTAssertEqual(first.byInstance["kinhin-c"]?.memoryUsedMB, 1024)
        XCTAssertNil(first.byInstance["kinhin-c"]?.cpuPercent, "the first sample only starts the baseline")

        let second = await sampler.snapshot(for: [record])
        let cpu = try XCTUnwrap(second.byInstance["kinhin-c"]?.cpuPercent)
        XCTAssertGreaterThan(cpu, 0, "the counter delta reads as a live percentage")
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
