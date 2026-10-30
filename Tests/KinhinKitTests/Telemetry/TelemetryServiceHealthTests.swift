import Foundation
import XCTest

@testable import KinhinKit
@testable import KinhinTestSupport

final class TelemetryServiceHealthTests: XCTestCase {
    private func makeEngine(_ recorder: RecordingTelemetryBackend) -> FleetEngine {
        var dependencies = FleetEngine.Dependencies(tokenLoader: { _, _ in "t" }, exitWatchInterval: .milliseconds(20))
        dependencies.telemetry = Telemetry(backend: recorder)
        return FleetEngine(
            config: makeTestConfig(), github: FakeGitHub(), tart: FakeTart(), store: makeTestStore(), ssh: FakeSSH(),
            host: testHost, dependencies: dependencies)
    }

    func testBuildInfoUptimeAndReconcileHealth() {
        let recorder = RecordingTelemetryBackend()
        let engine = makeEngine(recorder)
        engine.publishServiceHealth(now: engine.startedAt + 90)
        XCTAssertEqual(recorder.gauge(.buildInfo)?.first?.attributes[Metric.Attr.version], kinhinVersion.current)
        XCTAssertEqual(try XCTUnwrap(recorder.gauge(.daemonUptime)?.first?.value), 90, accuracy: 0.001)
        XCTAssertEqual(recorder.gauge(.reconcileLastSuccess)?.count, 0, "no pass yet: absent, not zero")

        let done = engine.startedAt + 100
        engine.recordReconcilePass(seconds: 0.4, now: done)
        engine.publishServiceHealth(now: done + 5)
        XCTAssertEqual(
            try XCTUnwrap(recorder.gauge(.reconcileLastSuccess)?.first?.value), done.timeIntervalSince1970,
            accuracy: 0.001)
        XCTAssertEqual(recorder.histograms(.reconcileDuration).first?.seconds, 0.4)
    }

    func testSpawnFailuresAndHolds() {
        let recorder = RecordingTelemetryBackend()
        let engine = makeEngine(recorder)
        engine.publishServiceHealth()
        XCTAssertEqual(recorder.gauge(.spawnHeld)?.count, 0, "nothing held")
        for _ in 0..<6 { engine.noteSpawnFailure(runtime: .tart, reason: "boom") }
        XCTAssertEqual(recorder.counterTotal(.spawnFailures) { $0[Metric.Attr.pool] == "tart" }, 6)
        engine.publishServiceHealth()
        let held = try? XCTUnwrap(recorder.gauge(.spawnHeld))
        XCTAssertEqual(held?.first?.attributes[Metric.Attr.holdReason], "backoff")
        XCTAssertEqual(held?.first?.attributes[Metric.Attr.pool], "tart")
        engine.diskHold.withLock { $0 = true }
        engine.publishServiceHealth()
        XCTAssertTrue(
            recorder.gauge(.spawnHeld)?.contains { $0.attributes[Metric.Attr.holdReason] == "disk_pressure" } ?? false)
    }

    func testQueueDepthByPoolAndAccount() {
        let recorder = RecordingTelemetryBackend()
        let engine = makeEngine(recorder)
        engine.publishQueueTelemetry(
            byForge: ["github": 3], byPool: [.tart: 2, .docker: 1], oldestEnqueuedAt: nil)
        XCTAssertEqual(recorder.gauge(.queueDepth)?.first?.value, 3)
        let pools = Dictionary(
            uniqueKeysWithValues: (recorder.gauge(.queueDepthByPool) ?? []).map {
                ($0.attributes[Metric.Attr.pool] ?? "", $0.value)
            })
        XCTAssertEqual(pools, ["tart": 2, "docker": 1])
    }

    func testReconcileLoopRecordsPassesAndErrors() async throws {
        let recorder = RecordingTelemetryBackend()
        let github = FakeGitHub()
        let engine = makeEngine(recorder)
        await engine.start()
        try await waitUntil(timeout: 10) { !recorder.histograms(.reconcileDuration).isEmpty }
        await engine.stop()
        XCTAssertNotNil(engine.lastReconcileSuccess.withLock { $0 })
        _ = github
    }
}
