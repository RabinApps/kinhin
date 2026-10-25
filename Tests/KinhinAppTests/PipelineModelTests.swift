import XCTest

@testable import KinhinKit
@testable import kinhin_app

/// The pipeline sheet: opening it from a busy VM row, listing the pipeline's
/// jobs, and drilling into one job's steps.
@MainActor
final class PipelineModelTests: MainWindowTestCase {
    private func detail(state: PipelineStepState = .running) -> PipelineDetail {
        let steps = [
            PipelineStep(name: "Checkout", state: .succeeded),
            PipelineStep(name: "Test", state: state == .running ? .running : .succeeded),
        ]
        return PipelineDetail(
            forge: .github, title: "CI", repository: "acme/api", ref: "main", sha: "abcdef1234567", state: state,
            jobs: [
                PipelineJob(id: "1", name: "build", state: state, steps: steps, isCurrent: true),
                PipelineJob(id: "2", name: "lint", state: .succeeded, steps: []),
            ], granularity: .step)
    }

    // MARK: - Opening

    func testBusyVMRowOpensItsPipelineSheet() {
        var busy = VMRecord(id: "kinhin-vm-1", phase: .busy)
        busy.job = "build"
        let idle = VMRecord(id: "kinhin-vm-2", phase: .ready)
        XCTAssertTrue(models.fleetModel.hasPipeline(busy))
        XCTAssertFalse(models.fleetModel.hasPipeline(idle), "an idle VM has no pipeline to show")

        models.fleetModel.pipelineClicked("kinhin-vm-1")
        XCTAssertEqual(tabs.sheet, .pipeline(vmID: "kinhin-vm-1"))
        XCTAssertEqual(models.pipelineModel?.vmID, "kinhin-vm-1")
        tabs.dismissSheet()
        XCTAssertNil(tabs.sheet)
    }

    // MARK: - Loading

    func testLoadShowsJobsAndNoticeForTheForge() async {
        fake.pipeline = detail()
        let model = models.makePipelineModel(vmID: "kinhin-vm-1")
        XCTAssertEqual(model.emptyMessage, "Loading…")

        await model.load()
        XCTAssertTrue(fake.calls.contains("pipelineDetail(kinhin-vm-1)"))
        XCTAssertNil(model.emptyMessage)
        XCTAssertEqual(model.title, "GitHub · CI")
        XCTAssertEqual(model.subtitle, "acme/api · main · abcdef1")
        XCTAssertEqual(model.detail?.jobs.map(\.name), ["build", "lint"])
        XCTAssertNil(model.notice, "GitHub reports steps")
    }

    func testJobLevelForgeSaysItHasNoSteps() async {
        let jobLevel = PipelineDetail(
            forge: .gitlab, title: "Pipeline #1", state: .running,
            jobs: [PipelineJob(id: "9", name: "test", state: .running, isCurrent: true)], granularity: .job)
        fake.pipeline = jobLevel
        let model = models.makePipelineModel(vmID: "kinhin-vm-1")
        await model.load()
        XCTAssertEqual(model.notice, "GitLab reports jobs, not individual steps.")
        model.select(jobLevel.jobs[0])
        XCTAssertEqual(model.stepsHint(for: jobLevel.jobs[0]), "GitLab exposes no steps for this job.")
    }

    func testNoRunningJobIsReportedNotAnError() async {
        let model = models.makePipelineModel(vmID: "kinhin-vm-1")
        await model.load()
        XCTAssertEqual(model.emptyMessage, "No job is running on this VM.")
        XCTAssertNil(model.error)
    }

    func testBackendFailureIsShown() async {
        fake.commandError = EngineError.unknownVM("kinhin-vm-1")
        let model = models.makePipelineModel(vmID: "kinhin-vm-1")
        await model.load()
        XCTAssertNotNil(model.error)
        XCTAssertEqual(model.emptyMessage, model.error)
    }

    func testFinishedJobKeepsLastStateAndSaysSo() async {
        fake.pipeline = detail()
        let model = models.makePipelineModel(vmID: "kinhin-vm-1")
        await model.load()
        fake.pipeline = nil
        await model.load()
        XCTAssertEqual(model.detail?.jobs.count, 2, "the last known pipeline stays readable")
        XCTAssertEqual(model.notice, "This job has finished; showing its last known state.")
    }

    func testTimingStopsTickingOnceThePipelineEnded() async throws {
        let start = Date().addingTimeInterval(-30)
        let running = PipelineJob(id: "1", name: "build", state: .running, startedAt: start, isCurrent: true)
        fake.pipeline = PipelineDetail(
            forge: .github, title: "CI", state: .running, startedAt: start, jobs: [running], granularity: .step)
        let model = models.makePipelineModel(vmID: "kinhin-vm-1")
        await model.load()
        fake.pipeline = nil
        await model.load()
        let soon = Date().addingTimeInterval(5)
        let later = Date().addingTimeInterval(500)
        XCTAssertEqual(model.timing(of: running, now: soon), model.timing(of: running, now: later))
    }

    func testFinishedItemsKeepAgingAfterThePipelineEnded() async throws {
        let start = Date().addingTimeInterval(-600)
        let done = PipelineJob(
            id: "1", name: "lint", state: .succeeded, startedAt: start, finishedAt: start.addingTimeInterval(30))
        fake.pipeline = PipelineDetail(
            forge: .github, title: "CI", state: .running, startedAt: start, jobs: [done], granularity: .step)
        let model = models.makePipelineModel(vmID: "kinhin-vm-1")
        await model.load()
        fake.pipeline = nil
        await model.load()
        let later = Date().addingTimeInterval(3_600)
        XCTAssertEqual(model.timing(of: done, now: later), "30s · finished 1h ago")
    }

    // MARK: - Drilling into one job

    func testSelectingAJobShowsOnlyItsStepsAndBackReturns() async throws {
        fake.pipeline = detail()
        let model = models.makePipelineModel(vmID: "kinhin-vm-1")
        await model.load()
        XCTAssertNil(model.selectedJob)

        model.select(try XCTUnwrap(model.detail?.jobs.first))
        XCTAssertEqual(model.selectedJob?.name, "build")
        XCTAssertEqual(model.selectedJob?.steps.map(\.name), ["Checkout", "Test"])

        model.back()
        XCTAssertNil(model.selectedJob)
    }

    // MARK: - Formatting

    func testDurationFormatting() {
        let start = Date(timeIntervalSince1970: 1_000)
        XCTAssertNil(PipelineModel.duration(from: nil, to: nil))
        XCTAssertEqual(PipelineModel.duration(from: start, to: start.addingTimeInterval(45)), "45s")
        XCTAssertEqual(PipelineModel.duration(from: start, to: start.addingTimeInterval(72)), "1m 12s")
        XCTAssertEqual(PipelineModel.duration(from: start, to: start.addingTimeInterval(3_720)), "1h 02m")
    }
}

/// The pipeline sheet's output pane: opening a step's output, following it,
/// and stepping back out.
@MainActor
final class PipelineOutputModelTests: MainWindowTestCase {
    private func loadedModel() async throws -> PipelineModel {
        fake.pipeline = PipelineDetail(
            forge: .github, title: "CI", state: .running,
            jobs: [
                PipelineJob(
                    id: "1", name: "build", state: .running,
                    steps: [
                        PipelineStep(name: "Checkout", state: .succeeded),
                        PipelineStep(name: "Test", state: .running),
                    ], isCurrent: true)
            ])
        let model = models.makePipelineModel(vmID: "kinhin-vm-1")
        await model.load()
        model.select(try XCTUnwrap(model.detail?.jobs.first))
        return model
    }

    func testOpeningAStepLoadsItsOutputAndRefreshFollowsIt() async throws {
        let model = try await loadedModel()
        model.selectStep(1)
        XCTAssertEqual(model.logTitle, "Test")
        XCTAssertEqual(model.logPlaceholder, "Loading output…")

        fake.pipelineLogResult = PipelineLog(text: "step one\n", scope: .step)
        await model.refresh()
        XCTAssertTrue(fake.calls.contains("pipelineLog(kinhin-vm-1,1,1)"))
        XCTAssertEqual(model.log?.text, "step one\n")
        XCTAssertNil(model.logPlaceholder)

        fake.pipelineLogResult = PipelineLog(text: "step one\nstep two\n", scope: .step)
        await model.refresh()
        XCTAssertEqual(model.log?.text, "step one\nstep two\n", "the open output follows new text")
    }

    func testWholeJobOutputUsesNoStepIndex() async throws {
        let model = try await loadedModel()
        fake.pipelineLogResult = PipelineLog(text: "all\n", scope: .job)
        model.selectJobOutput()
        await model.loadLog()
        XCTAssertTrue(fake.calls.contains("pipelineLog(kinhin-vm-1,1,-)"))
        XCTAssertEqual(model.logTitle, "build — whole job")
    }

    func testNoOutputFromTheForgeSaysSo() async throws {
        let model = try await loadedModel()
        fake.pipelineLogResult = nil
        model.selectStep(0)
        await model.loadLog()
        XCTAssertEqual(model.logPlaceholder, "GitHub has no output for this step (yet).")
    }

    func testBackLeavesTheOutputThenTheJob() async throws {
        let model = try await loadedModel()
        model.selectStep(0)
        model.back()
        XCTAssertNil(model.logTarget)
        XCTAssertNotNil(model.selectedJob, "back from output returns to the job's steps")
        model.back()
        XCTAssertNil(model.selectedJob)
    }

    func testFailureIsShownAndKeepsTheLastText() async throws {
        let model = try await loadedModel()
        fake.pipelineLogResult = PipelineLog(text: "partial\n", scope: .step)
        model.selectStep(1)
        await model.loadLog()
        fake.commandError = EngineError.unknownPipelineJob("1")
        await model.loadLog()
        XCTAssertNotNil(model.logError)
        XCTAssertEqual(model.log?.text, "partial\n", "a failed poll doesn't blank the output")
    }
}
