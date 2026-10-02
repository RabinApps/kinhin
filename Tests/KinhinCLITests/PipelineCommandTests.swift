import XCTest

@testable import KinhinKit
@testable import kinhin

/// `kinhin pipeline`: argument parsing and the text/JSON it prints.
final class PipelineCommandTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 1_000)

    private var detail: PipelineDetail {
        PipelineDetail(
            forge: .github, title: "CI", repository: "acme/api", ref: "main", sha: "abcdef1234567",
            url: "https://example.com/run/5", state: .running,
            jobs: [
                PipelineJob(
                    id: "1", name: "build", state: .running, startedAt: start,
                    steps: [
                        PipelineStep(
                            name: "Checkout", state: .succeeded, startedAt: start,
                            finishedAt: start.addingTimeInterval(4)),
                        PipelineStep(name: "Test", state: .running, startedAt: start.addingTimeInterval(5)),
                    ], isCurrent: true),
                PipelineJob(
                    id: "2", name: "lint", state: .succeeded, startedAt: start, finishedAt: start.addingTimeInterval(3),
                    steps: [PipelineStep(name: "swiftlint", state: .succeeded)]),
            ], granularity: .step)
    }

    // MARK: - Parsing

    func testParse() {
        XCTAssertEqual(PipelineCommand.parse(["pipeline"]), PipelineCommand.Options())
        XCTAssertEqual(PipelineCommand.parse(["pipeline", "kinhin-1"])?.vm, "kinhin-1")
        let full = PipelineCommand.parse(["pipeline", "kinhin-1", "--job", "build", "--json"])
        XCTAssertEqual(full, PipelineCommand.Options(vm: "kinhin-1", job: "build", watch: false, json: true))
        XCTAssertTrue(PipelineCommand.parse(["pipeline", "--watch"])?.watch == true)
        let output = PipelineCommand.parse(["pipeline", "kinhin-1", "--step", "3", "--follow"])
        XCTAssertEqual(output?.step, "3")
        XCTAssertTrue(output?.follow == true && output?.wantsOutput == true)
        XCTAssertTrue(PipelineCommand.parse(["pipeline", "--log", "-f"])?.log == true)
        XCTAssertNil(PipelineCommand.parse(["pipeline", "--step"]), "--step needs a value")
        XCTAssertNil(PipelineCommand.parse(["pipeline", "--job"]), "--job needs a value")
        XCTAssertNil(PipelineCommand.parse(["pipeline", "a", "b"]), "one VM at most")
        XCTAssertNil(PipelineCommand.parse(["pipeline", "--bogus"]))
    }

    // MARK: - Output

    func testOverviewListsJobsAndStepsOfTheVMsOwnJob() throws {
        let text = try PipelineCommand.format(
            [.init(vm: "kinhin-1", pipeline: detail)], options: .init(), requested: false,
            now: start.addingTimeInterval(125))
        XCTAssertTrue(text.contains("GitHub · CI  (kinhin-1)"))
        XCTAssertTrue(text.contains("acme/api · main · abcdef1"))
        XCTAssertTrue(text.contains("◐ build  [Running · 2m 05s · started 2m ago · this VM]"), text)
        XCTAssertTrue(text.contains("    ✓ Checkout  4s · finished 2m ago"), text)
        XCTAssertTrue(text.contains("    ◐ Test  2m 00s · started 2m ago"), text)
        XCTAssertTrue(text.contains("✓ lint  [Succeeded · 3s · finished 2m ago]"), text)
        XCTAssertFalse(text.contains("swiftlint"), "other jobs' steps only show when asked for")
    }

    func testJobFilterShowsOnlyThatJobsSteps() throws {
        let text = try PipelineCommand.format(
            [.init(vm: "kinhin-1", pipeline: detail)], options: .init(vm: "kinhin-1", job: "LINT"), requested: true)
        XCTAssertTrue(text.contains("swiftlint"))
        XCTAssertFalse(text.contains("build"))
        XCTAssertFalse(text.contains("Checkout"))
    }

    func testUnknownJobListsTheNames() {
        XCTAssertThrowsError(
            try PipelineCommand.format(
                [.init(vm: "kinhin-1", pipeline: detail)], options: .init(vm: "kinhin-1", job: "deploy"),
                requested: true)
        ) {
            XCTAssertEqual($0 as? PipelineCommandError, .unknownJob("deploy", ["build", "lint"]))
        }
    }

    func testJobLevelForgeSaysSoAndHintsNoSteps() throws {
        let jobLevel = PipelineDetail(
            forge: .gitlab, title: "Pipeline #1", state: .running,
            jobs: [PipelineJob(id: "9", name: "test", state: .running, isCurrent: true)], granularity: .job)
        let text = try PipelineCommand.format(
            [.init(vm: "kinhin-1", pipeline: jobLevel)], options: .init(job: "test"), requested: true)
        XCTAssertTrue(text.contains("GitLab reports jobs, not individual steps."))
        XCTAssertTrue(text.contains("GitLab exposes no steps for this job."))
    }

    func testIdleAndEmptyCases() throws {
        XCTAssertEqual(
            try PipelineCommand.format([.init(vm: "kinhin-2", pipeline: nil)], options: .init(), requested: true),
            "kinhin-2: no job is running.")
        XCTAssertEqual(try PipelineCommand.format([], options: .init(), requested: false), "no VM is running a job.")
    }

    func testJSONCarriesEveryVMsPipeline() throws {
        let text = try PipelineCommand.format(
            [.init(vm: "kinhin-1", pipeline: detail), .init(vm: "kinhin-2", pipeline: nil)],
            options: .init(json: true), requested: false)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(text.utf8)) as? [[String: Any]])
        XCTAssertEqual(object.map { $0["vm"] as? String }, ["kinhin-1", "kinhin-2"])
        XCTAssertNotNil(object[0]["pipeline"])
        XCTAssertNil(object[1]["pipeline"])
    }

    func testJobMatchingPrefersIdThenNameThenUniquePartial() {
        let pipeline = detail
        XCTAssertEqual(PipelineFormatter.job(matching: "2", in: pipeline)?.name, "lint")
        XCTAssertEqual(PipelineFormatter.job(matching: "Build", in: pipeline)?.id, "1")
        XCTAssertEqual(PipelineFormatter.job(matching: "li", in: pipeline)?.name, "lint")
        XCTAssertNil(PipelineFormatter.job(matching: "x", in: pipeline))
    }

    // MARK: - Output

    func testStepMatchingByNumberNameAndUniquePartial() {
        let job = detail.jobs[0]  // Checkout, Test
        XCTAssertEqual(PipelineCommand.stepIndex(matching: "2", in: job), 1)
        XCTAssertNil(PipelineCommand.stepIndex(matching: "3", in: job))
        XCTAssertEqual(PipelineCommand.stepIndex(matching: "checkout", in: job), 0)
        XCTAssertEqual(PipelineCommand.stepIndex(matching: "tes", in: job), 1)
        XCTAssertNil(PipelineCommand.stepIndex(matching: "e", in: job), "ambiguous")
    }

    func testTargetDefaultsToTheVMsOwnJob() throws {
        let target = try PipelineCommand.resolveTarget(.init(step: "Test"), in: detail)
        XCTAssertEqual(target.job.name, "build")
        XCTAssertEqual(target.stepIndex, 1)
        XCTAssertEqual(target.title, "build › Test")
        let wholeJob = try PipelineCommand.resolveTarget(.init(job: "lint", log: true), in: detail)
        XCTAssertNil(wholeJob.stepIndex)
        XCTAssertThrowsError(try PipelineCommand.resolveTarget(.init(step: "nope"), in: detail)) {
            XCTAssertEqual($0 as? PipelineCommandError, .unknownStep("nope", ["Checkout", "Test"]))
        }
    }

    func testFollowerPrintsOnlyNewOutput() {
        var follower = PipelineCommand.LogFollower()
        XCTAssertEqual(follower.delta("one\ntwo\n"), "one\ntwo\n")
        XCTAssertEqual(follower.delta("one\ntwo\n"), "", "nothing new")
        XCTAssertEqual(follower.delta("one\ntwo\nthree\n"), "three\n")
        // The log keeps only its recent part: its start is cut but the printed end still anchors.
        var long = PipelineCommand.LogFollower()
        let lines = (1...300).map { "line number \($0)" }
        _ = long.delta(lines.joined(separator: "\n") + "\n")
        let cut = (51...302).map { "line number \($0)" }.joined(separator: "\n") + "\n"
        XCTAssertEqual(long.delta(cut), "line number 301\nline number 302\n")
        XCTAssertTrue(follower.delta("unrelated\n").contains("output restarted"))
    }
}
