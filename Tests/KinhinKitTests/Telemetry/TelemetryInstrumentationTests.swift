import Foundation
import XCTest

@testable import KinhinKit
@testable import KinhinTestSupport

final class TelemetryInstrumentationTests: XCTestCase {
    private func makeEngine(
        recorder: RecordingTelemetryBackend?, tart: FakeTart, github: FakeGitHub
    ) -> FleetEngine {
        var dependencies = FleetEngine.Dependencies(
            tokenLoader: { _, _ in "test-token" }, exitWatchInterval: .milliseconds(20))
        if let recorder { dependencies.telemetry = Telemetry(backend: recorder) }
        return FleetEngine(
            config: makeTestConfig(), github: github, tart: tart, store: makeTestStore(), ssh: FakeSSH(),
            host: testHost, dependencies: dependencies)
    }

    private func runToReady(_ engine: FleetEngine, github: FakeGitHub) async throws -> String {
        github.queueDepth = 1
        try await engine.reconcileOnce()
        try await waitUntil(timeout: 10) { await engine.status().records.first?.phase == .ready }
        return await engine.status().records[0].id
    }

    func testLifecycleRecordsPhaseDurationsAndSpans() async throws {
        let recorder = RecordingTelemetryBackend()
        let github = FakeGitHub()
        let engine = makeEngine(recorder: recorder, tart: FakeTart(), github: github)
        let vm = try await runToReady(engine, github: github)

        let phases = Set(recorder.histograms(.phaseDuration).compactMap { $0.attributes[Metric.Attr.phase] })
        XCTAssertEqual(phases, ["clone", "boot", "register"])
        for sample in recorder.histograms(.phaseDuration) {
            XCTAssertGreaterThanOrEqual(sample.seconds, 0)
            XCTAssertEqual(sample.attributes[Metric.Attr.pool], "tart")
            XCTAssertEqual(sample.attributes[Metric.Attr.forge], "github")
        }

        let roots = recorder.spans(named: "kinhin.job")
        XCTAssertEqual(roots.count, 1)
        XCTAssertEqual(roots[0].attributes["kinhin.vm.id"], .string(vm), "ids live on spans")
        let children = recorder.spans.filter { $0.parent == roots[0].id }.map(\.name)
        XCTAssertEqual(Set(children), ["provision", "boot_ready", "registration"])
        XCTAssertTrue(recorder.spans.filter { $0.parent == roots[0].id }.allSatisfy(\.ended))
    }

    func testMetricAttributesStayBounded() async throws {
        let recorder = RecordingTelemetryBackend()
        let github = FakeGitHub()
        let engine = makeEngine(recorder: recorder, tart: FakeTart(), github: github)
        let vm = try await runToReady(engine, github: github)
        await engine.publishTelemetry()

        let forbiddenKeys = ["vm", "vm.id", "job", "run", "trace_id", "span_id", "id"]
        var attributeSets = recorder.counters.map(\.attributes) + recorder.histograms.map(\.attributes)
        for gauge in Metric.Gauge.allCases { attributeSets += (recorder.gauge(gauge) ?? []).map(\.attributes) }
        XCTAssertFalse(attributeSets.isEmpty)
        for attributes in attributeSets {
            for key in forbiddenKeys { XCTAssertNil(attributes[key], "\(attributes)") }
            XCTAssertNil(attributes[Metric.Attr.repository], "repository is opt-in")
            XCTAssertNil(attributes[Metric.Attr.workflow], "workflow is opt-in")
            for value in attributes.values {
                XCTAssertFalse(value.contains(vm), "metric attribute carries the VM id: \(attributes)")
                XCTAssertFalse(value.hasPrefix(InstanceNaming.prefix), "\(attributes)")
            }
        }
    }

    func testSnapshotGaugesAndUnavailableMeasurements() async throws {
        let recorder = RecordingTelemetryBackend()
        let github = FakeGitHub()
        let engine = makeEngine(recorder: recorder, tart: FakeTart(), github: github)
        _ = try await runToReady(engine, github: github)
        await engine.publishTelemetry()

        let workers = try XCTUnwrap(recorder.gauge(.workers))
        XCTAssertEqual(workers.map(\.value).reduce(0, +), 1)
        XCTAssertEqual(workers[0].attributes[Metric.Attr.state], "ready")
        XCTAssertEqual(workers[0].attributes[Metric.Attr.pool], "tart")
        XCTAssertEqual(workers[0].attributes[Metric.Attr.labels], "kinhin")
        XCTAssertEqual(recorder.gauge(.fleetActive)?.first?.value, 1)
        XCTAssertEqual(recorder.gauge(.fleetPaused)?.first?.value, 0)
        XCTAssertNotNil(recorder.gauge(.hostDiskFree)?.first)
        // Unavailable is absent, never zero: the fake tart reports no per-VM disk, and none is published.
        XCTAssertNil(recorder.gauge(.queueAge).flatMap { $0.isEmpty ? nil : $0 })
    }

    func testQueueAgeOnlyWithAProviderTimestamp() {
        let recorder = RecordingTelemetryBackend()
        let engine = makeEngine(recorder: recorder, tart: FakeTart(), github: FakeGitHub())
        let now = Date()
        engine.publishQueueTelemetry(byForge: ["github": 2], oldestEnqueuedAt: nil, now: now)
        XCTAssertEqual(recorder.gauge(.queueAge)?.count, 0, "no timestamp, no age")
        XCTAssertEqual(recorder.gauge(.queueDepth)?.first?.value, 2)
        engine.publishQueueTelemetry(byForge: [:], oldestEnqueuedAt: now.addingTimeInterval(-42), now: now)
        XCTAssertEqual(try XCTUnwrap(recorder.gauge(.queueAge)?.first?.value), 42, accuracy: 0.001)
    }

    func testJobPickupAndCompletionCountOnce() async throws {
        let recorder = RecordingTelemetryBackend()
        let github = FakeGitHub()
        let engine = makeEngine(recorder: recorder, tart: FakeTart(), github: github)
        let vm = try await runToReady(engine, github: github)

        github.register(name: vm, busy: true)
        try await waitUntil(timeout: 10) { await engine.status().records.first?.phase == .busy }
        github.deregister(name: vm)
        try await waitUntil(timeout: 10) { await engine.status().records.isEmpty }
        try await waitUntil(timeout: 10) { recorder.counterTotal(.jobsCompleted) == 1 }

        XCTAssertEqual(recorder.counterTotal(.jobsPickedUp), 1)
        XCTAssertEqual(recorder.counterTotal(.jobsCompleted), 1)
        XCTAssertEqual(recorder.histograms(.runDuration).count, 1)
        let root = try XCTUnwrap(recorder.spans(named: "kinhin.job").first)
        XCTAssertTrue(root.ended)
        XCTAssertEqual(root.attributes["kinhin.result"], .string("completed"))
        XCTAssertEqual(root.attributes[Metric.Attr.result], .string("unknown"), "FakeGitHub gives no verdict")
        XCTAssertTrue(recorder.spans(named: "teardown").first?.ended ?? false)
        XCTAssertEqual(recorder.spans(named: "run").count, 1)
    }

    func testShortJobNeverSeenRunningStillCountsWithoutAFabricatedDuration() async throws {
        let recorder = RecordingTelemetryBackend()
        let github = FakeGitHub()
        let engine = makeEngine(recorder: recorder, tart: FakeTart(), github: github)
        let vm = try await runToReady(engine, github: github)
        // The forge's event stream says the job finished; no poll ever saw the runner busy.
        await engine.noteJobFinished(id: vm)
        XCTAssertEqual(recorder.counterTotal(.jobsPickedUp), 1)
        XCTAssertEqual(recorder.counterTotal(.jobsCompleted), 1)
        XCTAssertTrue(recorder.histograms(.runDuration).isEmpty, "no observed start, no run duration")
        XCTAssertTrue(recorder.spans(named: "run").isEmpty)
        // Counted once however often the watcher repeats itself.
        await engine.noteJobFinished(id: vm)
        XCTAssertEqual(recorder.counterTotal(.jobsPickedUp), 1)
    }

    func testCloneFailureIsCountedOnceWithABoundedType() async throws {
        let recorder = RecordingTelemetryBackend()
        let tart = FakeTart()
        tart.failNextClone = true
        let github = FakeGitHub()
        let engine = makeEngine(recorder: recorder, tart: tart, github: github)
        github.queueDepth = 1
        try await engine.reconcileOnce()
        try await waitUntil(timeout: 10) { recorder.counterTotal(.errors) >= 1 }
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(recorder.counterTotal(.errors), 1)
        let error = try XCTUnwrap(recorder.counters.first { $0.name == Metric.Counter.errors.rawValue })
        XCTAssertEqual(error.attributes[Metric.Attr.errorType], "clone_failed")
        XCTAssertEqual(error.attributes[Metric.Attr.component], "lifecycle")
        XCTAssertEqual(error.attributes.count, 2, "no free-text error message as a dimension")
    }

    func testDisabledTelemetryChangesNothing() async throws {
        let github = FakeGitHub()
        let engine = makeEngine(recorder: nil, tart: FakeTart(), github: github)
        _ = try await runToReady(engine, github: github)
        await engine.publishTelemetry()
        XCTAssertFalse(engine.telemetry.isEnabled)
        XCTAssertTrue(engine.jobTraces.withLock { $0.values.allSatisfy { $0.context == nil } })
    }

    // MARK: - Job correlation

    func testCorrelationAttachesIdentifiersAndProviderQueueWait() throws {
        let recorder = RecordingTelemetryBackend()
        let trace = JobTrace(
            telemetry: Telemetry(backend: recorder), vm: "kinhin-1-aa", pool: "tart", image: "default",
            forge: "github", labels: ["b", "a"])
        let queued = Date(timeIntervalSince1970: 1_000)
        let started = Date(timeIntervalSince1970: 1_012)
        let wait = trace.attach(
            JobCorrelation(
                runID: "77", runAttempt: 2, jobID: "88", workflow: "CI", jobName: "build", repository: "acme/widgets",
                enqueuedAt: queued, startedAt: started))
        XCTAssertEqual(wait, 12)
        // Idempotent: a later poll of the same job adds nothing.
        XCTAssertNil(
            trace.attach(
                JobCorrelation(runID: "77", runAttempt: 2, jobID: "88", enqueuedAt: queued, startedAt: started)))

        let root = try XCTUnwrap(recorder.spans(named: "kinhin.job").first)
        XCTAssertEqual(root.attributes["cicd.pipeline.run.id"], .string("77"))
        XCTAssertEqual(root.attributes["kinhin.run.attempt"], .int(2))
        XCTAssertEqual(root.attributes["kinhin.job.id"], .string("88"))
        XCTAssertEqual(root.attributes[Metric.Attr.labels], .string("a,b"))
        let queueSpan = try XCTUnwrap(recorder.spans(named: "queue_wait").first)
        XCTAssertEqual(queueSpan.start, queued)
        XCTAssertEqual(queueSpan.end, started)
        XCTAssertEqual(queueSpan.parent, root.id)
    }

    func testMissingProviderTimestampsMakeNoQueueWait() {
        let recorder = RecordingTelemetryBackend()
        let trace = JobTrace(
            telemetry: Telemetry(backend: recorder), vm: "kinhin-1-bb", pool: "tart", image: "default",
            forge: "gitea", labels: nil)
        XCTAssertNil(trace.attach(JobCorrelation(jobID: "1", startedAt: Date())))
        XCTAssertNil(trace.attach(JobCorrelation(jobID: "2", enqueuedAt: Date())))
        XCTAssertTrue(recorder.spans(named: "queue_wait").isEmpty, "no fabricated interval")
    }

    func testProviderStepsNeedRealTimes() {
        let recorder = RecordingTelemetryBackend()
        let trace = JobTrace(
            telemetry: Telemetry(backend: recorder), vm: "kinhin-1-cc", pool: "tart", image: "default",
            forge: "github", labels: nil)
        let t0 = Date(timeIntervalSince1970: 10)
        trace.addProviderSteps([
            PipelineStep(name: "checkout", state: .succeeded, startedAt: t0, finishedAt: t0.addingTimeInterval(3)),
            PipelineStep(name: "never ran", state: .skipped),
            PipelineStep(name: "running", state: .running, startedAt: t0),
        ])
        XCTAssertEqual(recorder.spans(named: "step").count, 1)
    }

    func testGitHubJobPayloadYieldsCorrelation() throws {
        let json = """
            {"id": 88, "run_id": 77, "run_attempt": 3, "name": "build", "status": "queued", "labels": ["x"],
             "runner_name": null, "workflow_name": "CI", "created_at": "2026-01-02T03:04:05Z",
             "started_at": "2026-01-02T03:04:20Z"}
            """
        let job = try JSONDecoder().decode(GHJob.self, from: Data(json.utf8))
        let correlation = job.correlation(repository: "acme/widgets")
        XCTAssertEqual(correlation.runID, "77")
        XCTAssertEqual(correlation.runAttempt, 3)
        XCTAssertEqual(correlation.jobID, "88")
        XCTAssertEqual(correlation.workflow, "CI")
        let queued = try XCTUnwrap(correlation.enqueuedAt)
        XCTAssertEqual(try XCTUnwrap(correlation.startedAt).timeIntervalSince(queued), 15)
        XCTAssertNil(correlation.completedAt)
    }

    // MARK: - Classification

    func testErrorClassification() {
        struct Plain: Error {}
        typealias T = TelemetryErrorType
        XCTAssertEqual(
            T.classify(TartError.commandFailed(what: "clone", stderr: "x"), stage: .provision), .cloneFailure)
        XCTAssertEqual(T.cloneFailure.rawValue, "clone_failed")
        XCTAssertEqual(T.forgeAPIFailure.rawValue, "forge_api")
        XCTAssertEqual(T.classify(TartError.ipNotFound(vm: "v"), stage: .bootReady), .bootTimeout)
        XCTAssertEqual(T.classify(Plain(), stage: .bootReady), .bootTimeout)
        XCTAssertEqual(T.classify(ForgeAPIError.http(forge: .github, code: 429, body: ""), stage: nil), .rateLimited)
        XCTAssertEqual(T.classify(GitHubError.rateLimited(resetAt: Date()), stage: .registration), .rateLimited)
        XCTAssertEqual(
            T.classify(ForgeAPIError.http(forge: .gitlab, code: 500, body: ""), stage: nil), .forgeAPIFailure)
        XCTAssertEqual(
            T.classify(EngineError.registrationFailed(vm: "v", stderr: ""), stage: .registration), .registrationFailure)
        XCTAssertEqual(T.classify(Plain(), stage: nil), .unknown)
    }

    func testForgeStatusClasses() {
        XCTAssertEqual(ForgeRequestMetrics.statusClass(200), "2xx")
        XCTAssertEqual(ForgeRequestMetrics.statusClass(404), "4xx")
        XCTAssertEqual(ForgeRequestMetrics.statusClass(503), "5xx")
        XCTAssertEqual(ForgeRequestMetrics.statusClass(nil), "error")
    }
}
