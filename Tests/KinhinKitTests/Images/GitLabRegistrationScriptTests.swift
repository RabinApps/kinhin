import XCTest

@testable import KinhinKit
@testable import KinhinTestSupport

/// The single-job GitLab runner bootstrap on each runtime.
final class GitLabRegistrationScriptTests: XCTestCase {
    private let route = RepoRoute(repo: "acme/api", image: "img", ephemeral: true, bootTimeout: 30)

    private func forge() -> GitLabForge {
        GitLabForge(
            credentials: .gitlab(token: "glpat", scope: "acme/api", instance: "https://git.example.com/"),
            labels: ["macos"],
            client: GitLabClient(
                credentials: GitLabCredentials(token: "glpat", scope: "acme/api", instance: "https://git.example.com/")),
            scope: .project(id: 7, path: "acme/api"))
    }

    func testScriptRunsOneJobThenDeletesItsRunner() {
        let script = RunnerBootstrap.gitlabRegistrationScript(
            instance: "https://git.example.com/", runners: [("kinhin-1", "glrt-secret")],
            binary: "/opt/gitlab-runner/gitlab-runner", baseDir: "/opt/gitlab-runner")
        XCTAssertTrue(script.contains("run-single --description \"$2\" --executor shell"))
        XCTAssertTrue(script.contains("--max-builds 1"))
        XCTAssertTrue(script.contains("-X DELETE \"$1/api/v4/runners\""), "the runner deregisters itself")
        XCTAssertTrue(script.contains("'https://git.example.com' 'kinhin-1'"), "trailing slash trimmed")
        // The token reaches the runner's shell on a pipe (stdin of the bash
        // wrapper) — never on a command line, never in a file, and it appears
        // exactly once in the script.
        XCTAssertTrue(script.contains("printf '%s' 'glrt-secret' | nohup /bin/bash"))
        XCTAssertFalse(script.contains("> token"), "no token file is written")
        XCTAssertEqual(script.components(separatedBy: "glrt-secret").count, 2)
        // Deregistration also carries the token on curl's stdin, not in a file.
        XCTAssertTrue(script.contains("printf %s \"$CI_SERVER_TOKEN\" |"))
        XCTAssertFalse(script.contains("token=<token"))
    }

    func testMissingRunnerTokenFailsRegistration() {
        XCTAssertThrowsError(
            try RunnerBootstrap.gitlabRunners(name: "kinhin-1", runnerCount: 2, tokens: ["kinhin-1-r1": "a"]))
        XCTAssertEqual(
            try RunnerBootstrap.gitlabRunners(name: "kinhin-1", runnerCount: 1, tokens: ["kinhin-1": "a"]).map(\.name),
            ["kinhin-1"])
    }

    func testEachRuntimeUsesItsOwnAgentPaths() async throws {
        let tokens = ["kinhin-1": "glrt-1"]
        let tart = try await TartRuntime(tart: FakeTart(), bootTimeout: { 30 }).registrationScript(
            forge: forge(), token: "", runnerTokens: tokens, name: "kinhin-1", runnerCount: 1, route: route,
            labels: nil)
        XCTAssertTrue(tart.contains("\"$HOME/gitlab-runner/gitlab-runner\""), tart)

        let docker = try await DockerRuntime(shell: FakeShell(), image: "img", cpus: 2, memoryGB: 4)
            .registrationScript(
                forge: forge(), token: "", runnerTokens: tokens, name: "kinhin-1", runnerCount: 1, route: route,
                labels: nil)
        XCTAssertTrue(docker.contains("/opt/gitlab-runner/gitlab-runner"), docker)
    }
}
