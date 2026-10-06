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
        XCTAssertEqual(report.notices, ["--job build selected; its needs were not run"])
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
