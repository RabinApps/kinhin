import Foundation
import XCTest

@testable import KinhinKit
@testable import KinhinTestSupport

final class LocalWorkflowRunnerTests: XCTestCase {
    private func document(_ yaml: String) throws -> WorkflowDocument {
        try parseWorkflow(Data(yaml.utf8), at: URL(fileURLWithPath: "/repo/.github/workflows/test.yml"))
    }

    func testRunsJobsInNeedsOrderWithOneShellCallPerStep() async throws {
        let shell = FakeShell()
        shell.responses = [
            ShellResult(exitCode: 0, stdout: "", stderr: ""),
            ShellResult(exitCode: 0, stdout: "done", stderr: ""),
        ]
        let workflow = try document(
            """
            env:
              ROOT_VALUE: root
            jobs:
              build:
                needs: [setup]
                steps:
                  - run: echo build
              setup:
                env:
                  JOB_VALUE: job
                steps:
                  - run: echo 'NEXT_VALUE=next' >> "$GITHUB_ENV"
                  - run: echo "$ROOT_VALUE:$JOB_VALUE:$NEXT_VALUE"
            """)
        let report = try await LocalWorkflowRunner(shell: shell).run(
            document: workflow, workingDirectory: URL(fileURLWithPath: "/repo"))

        XCTAssertEqual(report.jobs.map(\.id), ["setup", "build"])
        XCTAssertEqual(report.overallState, .succeeded)
        XCTAssertEqual(shell.calls.count, 3)
        // The first call is setup's first step: the recorded stdin carries the
        // export preamble (which pins $GITHUB_ENV to the runner's temp file)
        // followed by the append itself.
        XCTAssertTrue(shell.calls[0].contains { $0.contains("GITHUB_ENV") })
        XCTAssertTrue(shell.calls[0].contains { $0.contains("NEXT_VALUE=next") })
        // The dependent job's step runs last, after setup's two steps.
        XCTAssertTrue(shell.calls[2].contains { $0.contains("echo build") })
        XCTAssertEqual(report.jobs[0].steps[1].output, "done")
    }

    /// The env-file contract needs a real shell: bash appends `KEY=VALUE` to
    /// `$GITHUB_ENV`, and the runner replays the file into the environment of
    /// every later step — across workflow, job, and step `env:` layers.
    func testValuesAppendedToGITHUBEnvReachLaterSteps() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("workflow-env-file-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let workflow = try document(
            """
            env:
              ROOT_VALUE: root
            jobs:
              setup:
                env:
                  JOB_VALUE: job
                steps:
                  - run: echo 'NEXT_VALUE=next' >> "$GITHUB_ENV"
                  - run: echo "$ROOT_VALUE:$JOB_VALUE:$NEXT_VALUE"
            """)
        let report = try await LocalWorkflowRunner(shell: Shell()).run(
            document: workflow, workingDirectory: root)

        XCTAssertEqual(report.overallState, .succeeded)
        XCTAssertEqual(
            report.jobs[0].steps[1].output?.trimmingCharacters(in: .whitespacesAndNewlines),
            "root:job:next",
            "step 2 sees workflow env, job env, and the value appended to $GITHUB_ENV by step 1")
    }

    func testContinuedFailureDoesNotFailJobButOrdinaryFailureSkipsLaterStepsAndJobs() async throws {
        let shell = FakeShell()
        shell.responses = [
            ShellResult(exitCode: 1, stdout: "", stderr: "ignored"),
            ShellResult(exitCode: 1, stdout: "", stderr: "failed"),
        ]
        let workflow = try document(
            """
            jobs:
              build:
                steps:
                  - run: echo ignored
                    continue-on-error: true
                  - run: echo fail
                  - run: echo skipped
              later:
                needs: [build]
                steps:
                  - run: echo later
            """)
        let report = try await LocalWorkflowRunner(shell: shell).run(
            document: workflow, workingDirectory: URL(fileURLWithPath: "/repo"))
        XCTAssertEqual(report.jobs.map(\.state), [.failed, .skipped])
        XCTAssertEqual(report.jobs[0].steps.map(\.state), [.failed, .failed, .skipped])
        XCTAssertEqual(shell.calls.count, 2)
    }

    func testCheckoutIsSuccessfulNoOpAndMatrixJobIsSkipped() async throws {
        let shell = FakeShell()
        let workflow = try document(
            """
            jobs:
              checkout:
                steps:
                  - uses: actions/checkout@v4
              matrix:
                strategy:
                  matrix:
                    os: [macos-latest, ubuntu-latest]
                steps:
                  - run: echo never
            """)
        let report = try await LocalWorkflowRunner(shell: shell).run(
            document: workflow, workingDirectory: URL(fileURLWithPath: "/repo"))
        XCTAssertEqual(report.jobs.map(\.state), [.succeeded, .skipped])
        XCTAssertEqual(report.jobs[0].steps.first?.state, .succeeded)
        XCTAssertEqual(shell.calls.count, 0)
    }

    // MARK: - Partial results

    private func run(_ yaml: String, responses: [ShellResult] = []) async throws -> LocalRunReport {
        let shell = FakeShell()
        shell.responses = responses
        return try await LocalWorkflowRunner(shell: shell).run(
            document: try document(yaml), workingDirectory: URL(fileURLWithPath: "/repo"))
    }

    func testBashStepsRunWithGitHubsFlags() async throws {
        let shell = FakeShell()
        _ = try await LocalWorkflowRunner(shell: shell).run(
            document: try document("jobs:\n  a:\n    steps:\n      - run: echo hi\n"),
            workingDirectory: URL(fileURLWithPath: "/repo"))
        XCTAssertEqual(
            Array(shell.calls[0].prefix(7)),
            ["/bin/bash", "--noprofile", "--norc", "-e", "-o", "pipefail", "-s"])
    }

    /// pipefail needs a real shell: `false | cat` must fail the step, as it
    /// does on GitHub, and a profile/rc file must not leak into the run.
    func testAFailingPipelineStageFailsTheStep() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("workflow-pipefail-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let report = try await LocalWorkflowRunner(shell: Shell()).run(
            document: try document("jobs:\n  a:\n    steps:\n      - run: false | cat\n"), workingDirectory: root)
        XCTAssertEqual(report.outcome, .failed)
    }

    func testCleanRunIsSucceededAndExitsZeroEvenWithoutLenient() async throws {
        let report = try await run("jobs:\n  a:\n    steps:\n      - run: echo hi\n")
        XCTAssertEqual(report.outcome, .succeeded)
        XCTAssertEqual(report.unsupportedSkips, [])
        XCTAssertEqual(report.exitCode(), 0)
    }

    func testThirdPartyActionMakesTheRunPartialNotASuccess() async throws {
        let report = try await run(
            """
            jobs:
              a:
                steps:
                  - uses: actions/checkout@v4
                  - uses: acme/deploy@v1
                  - run: echo hi
            """)
        XCTAssertEqual(report.jobs[0].state, .succeeded, "the job's own steps passed")
        XCTAssertEqual(report.jobs[0].steps.map(\.skippedAsUnsupported), [false, true, false])
        XCTAssertEqual(report.outcome, .partial)
        XCTAssertNotEqual(report.overallState, .succeeded)
        XCTAssertEqual(report.exitCode(), 1)
        XCTAssertEqual(report.exitCode(lenient: true), 0)
        XCTAssertEqual(report.unsupportedSkips.count, 1)
        XCTAssertTrue(report.unsupportedSkips[0].hasPrefix("a / "), report.unsupportedSkips[0])
        XCTAssertTrue(report.notices.contains { $0.contains("partial") }, "\(report.notices)")
    }

    func testUnsupportedConditionMakesTheRunPartial() async throws {
        let report = try await run(
            """
            jobs:
              a:
                steps:
                  - run: echo only on main
                    if: github.ref == 'refs/heads/main'
            """)
        XCTAssertEqual(report.jobs[0].steps[0].state, .skipped)
        XCTAssertTrue(report.jobs[0].steps[0].skippedAsUnsupported)
        XCTAssertEqual(report.outcome, .partial)
        XCTAssertEqual(report.exitCode(), 1)
        XCTAssertEqual(report.exitCode(lenient: true), 0)
    }

    func testDeliberateSkipsStayASuccess() async throws {
        let report = try await run(
            """
            jobs:
              a:
                steps:
                  - run: echo hi
                  - run: echo never
                    if: false
            """)
        XCTAssertEqual(report.jobs[0].steps[1].state, .skipped)
        XCTAssertFalse(report.jobs[0].steps[1].skippedAsUnsupported, "if: false is a decision, not a gap")
        XCTAssertEqual(report.outcome, .succeeded)
    }

    func testMatrixJobMakesTheRunPartial() async throws {
        let report = try await run(
            """
            jobs:
              m:
                strategy:
                  matrix:
                    os: [a, b]
                steps:
                  - run: echo never
            """)
        XCTAssertTrue(report.jobs[0].skippedAsUnsupported)
        XCTAssertEqual(report.outcome, .partial)
    }

    func testAFailureStaysFailedEvenWithLenient() async throws {
        let report = try await run(
            """
            jobs:
              a:
                steps:
                  - uses: acme/deploy@v1
                  - run: exit 1
            """,
            responses: [ShellResult(exitCode: 1, stdout: "", stderr: "boom")])
        XCTAssertEqual(report.outcome, .failed)
        XCTAssertEqual(report.exitCode(lenient: true), 1)
    }

    func testJSONCarriesTheOutcomeAndTheUnsupportedList() async throws {
        let report = try await run("jobs:\n  a:\n    steps:\n      - uses: acme/deploy@v1\n")
        let data = try JSONEncoder().encode(report)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(object["outcome"] as? String, "partial")
        XCTAssertEqual((object["unsupportedSkips"] as? [String])?.count, 1)
        let decoded = try JSONDecoder().decode(LocalRunReport.self, from: data)
        XCTAssertEqual(decoded, report, "derived keys are ignored on decode")
    }

    func testEveryRunNotesThatStepsAreNotIsolated() async throws {
        let report = try await run("jobs:\n  a:\n    steps:\n      - run: echo hi\n")
        XCTAssertEqual(report.notices.first, LocalWorkflowRunner.isolationNotice)
        XCTAssertTrue(LocalWorkflowRunner.isolationNotice.contains("directly on this Mac"))
    }

    func testSelectedJobDoesNotRunItsNeeds() async throws {
        let shell = FakeShell()
        let workflow = try document(
            """
            jobs:
              setup:
                steps:
                  - run: echo setup
              build:
                needs: [setup]
                steps:
                  - run: echo build
            """)
        let report = try await LocalWorkflowRunner(shell: shell).run(
            document: workflow, jobs: ["build"], workingDirectory: URL(fileURLWithPath: "/repo"))
        XCTAssertEqual(report.jobs.map(\.id), ["build"])
        XCTAssertEqual(shell.calls.count, 1)
        XCTAssertEqual(
            report.notices, [LocalWorkflowRunner.isolationNotice, "--job build selected; its needs were not run"])
    }

    func testDetectsDependencyCycles() async throws {
        let workflow = try document(
            """
            jobs:
              a:
                needs: [b]
                steps: []
              b:
                needs: [a]
                steps: []
            """)
        do {
            _ = try await LocalWorkflowRunner(shell: FakeShell()).run(
                document: workflow, workingDirectory: URL(fileURLWithPath: "/repo"))
            XCTFail("expected a cycle error")
        } catch WorkflowError.cyclicNeeds {
            // Expected.
        }
    }
}
