import Foundation
import XCTest

@testable import KinhinKit
@testable import KinhinTestSupport

final class LocalWorkflowRunnerTests: XCTestCase {
    private func document(_ yaml: String) throws -> WorkflowDocument {
        try parseWorkflow(Data(yaml.utf8), at: URL(fileURLWithPath: "/repo/.github/workflows/test.yml"))
    }

    func testRunsJobsInNeedsOrderAndCarriesEnvironmentFiles() async throws {
        let shell = FakeShell()
        shell.responses = [
            ShellResult(exitCode: 0, stdout: "", stderr: ""),
            ShellResult(exitCode: 0, stdout: "done", stderr: ""),
        ]
        let workflow = try document("""
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
        XCTAssertTrue(shell.calls[0].contains("GITHUB_ENV"))
        XCTAssertTrue(shell.calls[2].contains("NEXT_VALUE=next"))
        XCTAssertEqual(report.jobs[0].steps[1].output, "done")
    }

    func testContinuedFailureDoesNotFailJobButOrdinaryFailureSkipsLaterStepsAndJobs() async throws {
        let shell = FakeShell()
        shell.responses = [
            ShellResult(exitCode: 1, stdout: "", stderr: "ignored"),
            ShellResult(exitCode: 1, stdout: "", stderr: "failed"),
        ]
        let workflow = try document("""
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
        let workflow = try document("""
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
        let workflow = try document("""
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
        let workflow = try document("""
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
