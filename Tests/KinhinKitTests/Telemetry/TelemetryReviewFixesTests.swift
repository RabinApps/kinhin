import Foundation
import Network
import Synchronization
import XCTest

@testable import KinhinKit
@testable import KinhinTestSupport

/// Regression tests for the code-review findings on the telemetry work.
final class TelemetryReviewFixesTests: XCTestCase {
    private func makeEngine(_ recorder: RecordingTelemetryBackend) -> FleetEngine {
        var dependencies = FleetEngine.Dependencies(tokenLoader: { _, _ in "t" }, exitWatchInterval: .milliseconds(20))
        dependencies.telemetry = Telemetry(backend: recorder)
        return FleetEngine(
            config: makeTestConfig(), github: FakeGitHub(), tart: FakeTart(), store: makeTestStore(),
            ssh: FakeSSH(), host: testHost, dependencies: dependencies)
    }

    private func trace(_ engine: FleetEngine, id: String) -> JobTrace {
        let trace = engine.makeJobTrace(id: id)
        engine.jobTraces.withLock { $0[id] = trace }
        return trace
    }

    // MARK: - Shutdown never hangs on a slow collector

    private final class SlowBackend: TelemetryBackend, @unchecked Sendable {
        let released = Mutex(false)
        func add(counter name: String, value: Int, attributes: MetricAttributes) {}
        func record(histogram name: String, seconds: Double, attributes: MetricAttributes) {}
        func publish(gauge name: String, series: [GaugeSeries]) {}
        func startSpan(_ name: String, start: Date?, attributes: TelemetryAttributes) -> any TelemetrySpan {
            NoopSpan()
        }
        func emit(log: TelemetryLogRecord) {}
        func releaseListeners() { released.withLock { $0 = true } }
        func shutdown() async { try? await Task.sleep(for: .seconds(30)) }  // a dead collector's export timeout
    }

    func testReloadDoesNotWaitOutASlowFlush() async throws {
        let slow = SlowBackend()
        let service = TelemetryService(
            environment: { [:] }, makeBackend: { _ in slow }, shutdownTimeout: .milliseconds(200))
        await service.apply(KinhinConfig.TelemetryConfig(enabled: true))
        let started = ContinuousClock.now
        let outcome = await service.apply(.default)
        XCTAssertEqual(outcome, .disabled)
        XCTAssertLessThan(ContinuousClock.now - started, .seconds(5), "a reload must not wait for the collector")
        XCTAssertTrue(slow.released.withLock { $0 }, "listeners are released before the flush")
    }

    // MARK: - Cancellation is not a failure

    func testCancelledLifecycleCallIsNotCountedAsAnError() async throws {
        let recorder = RecordingTelemetryBackend()
        let engine = makeEngine(recorder)
        _ = trace(engine, id: "kinhin-1-aa")
        let task = Task {
            try? await engine.timed(.provision, id: "kinhin-1-aa") {
                while !Task.isCancelled { await Task.yield() }
                throw URLError(.cancelled)  // what a cancelled callee surfaces
            }
        }
        task.cancel()
        await task.value
        XCTAssertEqual(recorder.counterTotal(.errors), 0)
        XCTAssertTrue(recorder.histograms(.phaseDuration).isEmpty)
    }

    func testRealFailureIsStillCountedOnce() async throws {
        let recorder = RecordingTelemetryBackend()
        let engine = makeEngine(recorder)
        _ = trace(engine, id: "kinhin-1-bb")
        _ = try? await engine.timed(.provision, id: "kinhin-1-bb") {
            throw TartError.commandFailed(what: "clone", stderr: "")
        }
        XCTAssertEqual(recorder.counterTotal(.errors), 1)
    }

    // MARK: - Healing actions count only what happens during this engine's life

    func testHealingJournalHistoryIsNotRecounted() {
        let recorder = RecordingTelemetryBackend()
        let engine = makeEngine(recorder)
        let signal = HealingSignal(kind: .diskPressure, detail: "full")
        func event(_ id: String, _ outcome: HealingEvent.Outcome) -> HealingEvent {
            HealingEvent(id: id, signal: signal, remediation: nil, source: .playbook, outcome: outcome, detail: "x")
        }
        let old = [event("h-1", .succeeded), event("h-2", .failed), event("h-3", .pending)]
        engine.recordHealingTelemetry(HealingSnapshot(enabled: true, automatic: true, advisor: nil, events: old))
        XCTAssertEqual(
            recorder.counterTotal(.healingActions), 0, "history before this start is not an action taken now")
        XCTAssertEqual(recorder.gauge(.healingPending)?.first?.value, 1)

        // The pending one is approved and succeeds, and a new one fails: both are new.
        let now = [event("h-1", .succeeded), event("h-2", .failed), event("h-3", .succeeded), event("h-4", .failed)]
        engine.recordHealingTelemetry(HealingSnapshot(enabled: true, automatic: true, advisor: nil, events: now))
        XCTAssertEqual(recorder.counterTotal(.healingActions), 2)
        engine.recordHealingTelemetry(HealingSnapshot(enabled: true, automatic: true, advisor: nil, events: now))
        XCTAssertEqual(recorder.counterTotal(.healingActions), 2, "counted once")
    }

    // MARK: - Trace result is a bounded label

    func testTraceResultIsBounded() {
        let reasons = [
            "jobs finished": "completed", "failed: tart clone failed: secret-ish text": "failed",
            "scale down": "scaled_down", "cancelled remotely": "scaled_down", "warm instance evicted": "evicted",
            "registration timeout": "timeout", "timeout": "timeout", "instance gone": "deleted",
            "cleanup after restart": "deleted",
        ]
        for (reason, expected) in reasons {
            XCTAssertEqual(FleetEngine.traceResult(forDeleteReason: reason), expected, reason)
        }
    }

    // MARK: - Log context follows the job

    func testJobNameReachesTheLogContext() {
        let recorder = RecordingTelemetryBackend()
        let engine = makeEngine(recorder)
        let trace = trace(engine, id: "kinhin-2-cc")
        XCTAssertNil(trace.logContext.job)
        engine.noteJobCorrelation(vm: "kinhin-2-cc", JobCorrelation(runID: "1", jobID: "2", jobName: "build"))
        XCTAssertEqual(trace.logContext.job, "build")
        XCTAssertEqual(
            Log.Fields(component: "engine", context: trace.logContext).attributes["kinhin.job.name"], "build")
    }

    // MARK: - Several jobs on one instance

    func testSecondJobDoesNotOverwriteTheFirstOnTheRoot() throws {
        let recorder = RecordingTelemetryBackend()
        let trace = JobTrace(
            telemetry: Telemetry(backend: recorder), vm: "kinhin-3-dd", pool: "tart", image: "default",
            forge: "github", labels: nil)
        let t0 = Date(timeIntervalSince1970: 100)
        trace.attach(JobCorrelation(runID: "1", jobID: "10", jobName: "first", enqueuedAt: t0, startedAt: t0 + 5))
        let wait = trace.attach(
            JobCorrelation(runID: "2", jobID: "20", jobName: "second", enqueuedAt: t0, startedAt: t0 + 9))
        XCTAssertEqual(wait, 9)
        // Seeing either again adds nothing.
        XCTAssertNil(trace.attach(JobCorrelation(runID: "2", jobID: "20", jobName: "second")))
        XCTAssertNil(trace.attach(JobCorrelation(runID: "1", jobID: "10", jobName: "first")))

        let root = try XCTUnwrap(recorder.spans(named: "kinhin.job").first)
        XCTAssertEqual(root.attributes["kinhin.job.id"], .string("10"), "the root keeps the first job")
        let extra = recorder.spans(named: "job")
        XCTAssertEqual(extra.count, 1)
        XCTAssertEqual(extra[0].attributes["kinhin.job.id"], .string("20"))
        XCTAssertEqual(extra[0].parent, root.id)
        XCTAssertEqual(recorder.spans(named: "queue_wait").count, 2)
    }

    // MARK: - Prometheus listener hardening

    private func exchange(port: Int, parts: [String], pause: Duration = .milliseconds(150)) async -> String {
        let connection = NWConnection(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: UInt16(port))!, using: .tcp)
        let queue = DispatchQueue(label: "test.client")  // rules-lint only covers Sources
        connection.start(queue: queue)
        for part in parts {
            connection.send(content: Data(part.utf8), completion: .contentProcessed { _ in })
            try? await Task.sleep(for: pause)
        }
        return await withCheckedContinuation { continuation in
            connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { data, _, _, _ in
                connection.cancel()
                continuation.resume(returning: data.map { String(decoding: $0, as: UTF8.self) } ?? "")
            }
        }
    }

    func testRequestSplitAcrossSegmentsIsServed() async throws {
        let listener = try PrometheusListener(address: TelemetryListenAddress(host: "127.0.0.1", port: 0)) { "ok" }
        defer { listener.stop() }
        let reply = await exchange(port: listener.port, parts: ["GET /met", "rics HTTP/1.1\r\nHost: a\r\n", "\r\n"])
        XCTAssertTrue(reply.hasPrefix("HTTP/1.1 200"), reply)
    }

    func testIdleConnectionIsDropped() async throws {
        let listener = try PrometheusListener(
            address: TelemetryListenAddress(host: "127.0.0.1", port: 0), idleTimeout: 0.3
        ) {
            "ok"
        }
        defer { listener.stop() }
        // A client that connects and says nothing is closed by the server, so the read returns empty.
        let started = ContinuousClock.now
        let reply = await exchange(port: listener.port, parts: [])
        XCTAssertEqual(reply, "")
        XCTAssertLessThan(ContinuousClock.now - started, .seconds(5))
    }
}
