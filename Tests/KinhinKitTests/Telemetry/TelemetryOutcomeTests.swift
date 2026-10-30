import Foundation
import XCTest

@testable import KinhinKit
@testable import KinhinTestSupport

/// The forge's verdict, times and steps for a finished job, the opt-in job dimensions, and the issue-#64 names.
final class TelemetryOutcomeTests: XCTestCase {
    private func makeEngine(_ recorder: RecordingTelemetryBackend, github: FakeGitHub) -> FleetEngine {
        var dependencies = FleetEngine.Dependencies(tokenLoader: { _, _ in "t" }, exitWatchInterval: .milliseconds(20))
        dependencies.telemetry = Telemetry(backend: recorder)
        return FleetEngine(
            config: makeTestConfig(), github: github, tart: FakeTart(), store: makeTestStore(), ssh: FakeSSH(),
            host: testHost, dependencies: dependencies)
    }

    private func readyVM(_ engine: FleetEngine, github: FakeGitHub) async throws -> String {
        github.queueDepth = 1
        try await engine.reconcileOnce()
        try await waitUntil(timeout: 10) { await engine.status().records.first?.phase == .ready }
        return await engine.status().records[0].id
    }

    private let t0 = Date(timeIntervalSince1970: 1_000)

    func testForgeVerdictTimesAndStepsReachMetricsAndTrace() async throws {
        let recorder = RecordingTelemetryBackend()
        let github = FakeGitHub()
        let engine = makeEngine(recorder, github: github)
        let vm = try await readyVM(engine, github: github)
        engine.noteJobCorrelation(
            vm: vm,
            JobCorrelation(
                runID: "7", runAttempt: 1, jobID: "42", workflow: "CI", jobName: "build", repository: "acme/widgets",
                enqueuedAt: t0, startedAt: t0 + 4))
        github.jobOutcomes[42] = JobOutcome(
            result: .failure, startedAt: t0 + 4, completedAt: t0 + 34,
            steps: [
                PipelineStep(name: "checkout", state: .succeeded, startedAt: t0 + 4, finishedAt: t0 + 6),
                PipelineStep(name: "test", state: .failed, startedAt: t0 + 6, finishedAt: t0 + 34),
            ])
        await engine.noteJobFinished(id: vm)

        XCTAssertEqual(recorder.counterTotal(.jobsCompleted) { $0[Metric.Attr.result] == "failure" }, 1)
        let run = try XCTUnwrap(recorder.histograms(.runDuration).first)
        XCTAssertEqual(run.seconds, 30, accuracy: 0.001, "the forge's own times win over kinhin's polling")
        XCTAssertEqual(run.attributes[Metric.Attr.result], "failure")
        let root = try XCTUnwrap(recorder.spans(named: "kinhin.job").first)
        XCTAssertEqual(root.attributes[Metric.Attr.result], .string("failure"))
        let steps = recorder.spans(named: "step")
        XCTAssertEqual(steps.map { $0.attributes["cicd.pipeline.task.name"] }, [.string("checkout"), .string("test")])
        XCTAssertEqual(steps[1].error, "step failed")
        XCTAssertEqual(github.jobOutcomeCalls, 1)
    }

    func testUnknownVerdictIsReportedAsUnknownNotGuessed() async throws {
        let recorder = RecordingTelemetryBackend()
        let github = FakeGitHub()
        let engine = makeEngine(recorder, github: github)
        let vm = try await readyVM(engine, github: github)
        engine.noteJobCorrelation(vm: vm, JobCorrelation(runID: "7", jobID: "43", repository: "acme/widgets"))
        // The job has not reached completed on the forge yet: asked a few times, then unknown.
        github.jobOutcomes[43] = JobOutcome()
        await engine.noteJobFinished(id: vm)
        XCTAssertEqual(recorder.counterTotal(.jobsCompleted) { $0[Metric.Attr.result] == "unknown" }, 1)
        XCTAssertEqual(github.jobOutcomeCalls, 4, "bounded retries")
        XCTAssertTrue(recorder.spans(named: "step").isEmpty)
    }

    func testNoCorrelationMeansNoForgeCall() async throws {
        let recorder = RecordingTelemetryBackend()
        let github = FakeGitHub()
        let engine = makeEngine(recorder, github: github)
        let vm = try await readyVM(engine, github: github)
        await engine.noteJobFinished(id: vm)
        XCTAssertEqual(github.jobOutcomeCalls, 0)
        XCTAssertEqual(recorder.counterTotal(.jobsCompleted) { $0[Metric.Attr.result] == "unknown" }, 1)
    }

    func testRepositoryAndWorkflowAreOptInDimensions() async throws {
        for enabled in [false, true] {
            let recorder = RecordingTelemetryBackend()
            let github = FakeGitHub()
            let engine = makeEngine(recorder, github: github)
            if enabled { engine.telemetry.setJobAttributes([.repository, .workflow]) }
            let vm = try await readyVM(engine, github: github)
            engine.noteJobCorrelation(
                vm: vm,
                JobCorrelation(
                    runID: "7", jobID: "44", workflow: "CI", repository: "acme/widgets", enqueuedAt: t0,
                    startedAt: t0 + 2))
            github.jobOutcomes[44] = JobOutcome(result: .success, startedAt: t0 + 2, completedAt: t0 + 12)
            await engine.noteJobFinished(id: vm)
            let sets =
                recorder.counters.filter { $0.name == Metric.Counter.jobsCompleted.rawValue }.map(\.attributes)
                + recorder.histograms.map(\.attributes)
            let withRepo = sets.contains { $0[Metric.Attr.repository] == "acme/widgets" }
            let withFlow = sets.contains { $0[Metric.Attr.workflow] == "CI" }
            XCTAssertEqual(withRepo, enabled, "repository dimension, enabled=\(enabled)")
            XCTAssertEqual(withFlow, enabled, "workflow dimension, enabled=\(enabled)")
            // Never on the pickup counter (it is counted before the forge names the job) or any gauge.
            XCTAssertTrue(
                recorder.counters.filter { $0.name == Metric.Counter.jobsPickedUp.rawValue }.allSatisfy {
                    $0.attributes[Metric.Attr.repository] == nil
                })
        }
    }

    func testGitHubConclusionsMapToSemconvResults() {
        typealias R = JobOutcome.Result
        XCTAssertEqual(JobOutcome.result(gitHubConclusion: "success"), R.success)
        XCTAssertEqual(JobOutcome.result(gitHubConclusion: "failure"), R.failure)
        XCTAssertEqual(JobOutcome.result(gitHubConclusion: "cancelled"), R.cancellation)
        XCTAssertEqual(JobOutcome.result(gitHubConclusion: "timed_out"), R.timeout)
        XCTAssertEqual(JobOutcome.result(gitHubConclusion: "skipped"), R.skip)
        XCTAssertNil(JobOutcome.result(gitHubConclusion: "neutral"))
        XCTAssertNil(JobOutcome.result(gitHubConclusion: nil))
    }

    func testPoolCapacityAndRenamedMetrics() async throws {
        let recorder = RecordingTelemetryBackend()
        let github = FakeGitHub()
        let engine = makeEngine(recorder, github: github)
        _ = try await readyVM(engine, github: github)
        await engine.publishTelemetry()
        let capacity = try XCTUnwrap(recorder.gauge(.poolCapacity))
        XCTAssertTrue(capacity.contains { $0.attributes[Metric.Attr.pool] == "tart" && $0.value >= 1 })
        // The names issue #64 asks for.
        XCTAssertEqual(Metric.Gauge.workers.rawValue, "cicd.worker.count")
        XCTAssertEqual(Metric.Histogram.phaseDuration.rawValue, "kinhin.runner.provision.duration")
        XCTAssertEqual(Metric.Histogram.runDuration.rawValue, "cicd.pipeline.run.duration")
        XCTAssertEqual(Metric.Counter.errors.rawValue, "cicd.system.errors")
        XCTAssertEqual(Metric.Counter.forgeRequests.rawValue, "kinhin.forge.api.requests")
        XCTAssertEqual(Metric.Gauge.queueAge.rawValue, "kinhin.queue.age")
        XCTAssertEqual(Metric.Gauge.poolCapacity.rawValue, "kinhin.pool.capacity")
        XCTAssertEqual(Metric.Gauge.processCPU.rawValue, "process.cpu.utilization")
        XCTAssertEqual(Metric.Attr.errorType, "error.type")
        XCTAssertEqual(Metric.Attr.component, "cicd.system.component")
        XCTAssertEqual(Metric.Attr.state, "cicd.worker.state")
        XCTAssertEqual(Metric.Attr.pool, "kinhin.pool")
    }

    func testJobIDReachesTheLogContext() {
        let recorder = RecordingTelemetryBackend()
        let trace = JobTrace(
            telemetry: Telemetry(backend: recorder), vm: "kinhin-5-ee", pool: "tart", image: "default", forge: "github",
            labels: nil)
        trace.attach(JobCorrelation(runID: "7", jobID: "99", jobName: "build"))
        let attributes = Log.Fields(component: "x", context: trace.logContext).attributes
        XCTAssertEqual(attributes["kinhin.job.id"], "99")
        XCTAssertEqual(attributes["kinhin.job.name"], "build")
        let json = Log.Entry(timestamp: Date(), level: "info", component: "x", message: "m")
            .json(Log.Fields(component: "x", context: trace.logContext))
        XCTAssertTrue(json.contains("\"job_id\":\"99\""), json)
    }
}
