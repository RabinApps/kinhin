import XCTest

@testable import KinhinKit
@testable import KinhinTestSupport

/// The single-job Buildkite agent bootstrap on each runtime.
final class BuildkiteRegistrationScriptTests: XCTestCase {
    private let route = RepoRoute(repo: "acme", image: "img", ephemeral: true, bootTimeout: 30)

    private func forge() -> BuildkiteForge {
        BuildkiteForge(
            credentials: ForgeCredentials(forge: .buildkite, token: "bkua", scope: "acme/default"),
            labels: ["queue=kinhin"],
            client: BuildkiteClient(credentials: BuildkiteCredentials(token: "bkua", scope: "acme/default")),
            cluster: BuildkiteCluster(id: "c-1", name: "default"), agentToken: "bkct-secret")
    }

    func testScriptRunsOneJobPerAgentWithAPrivateToken() {
        let script = RunnerBootstrap.buildkiteRegistrationScript(
            token: "bkct-secret", tags: ["queue=kinhin", "os=macos"], runnerNames: ["kinhin-1-r1", "kinhin-1-r2"],
            binary: "/opt/buildkite-agent/buildkite-agent", baseDir: "/opt/buildkite-agent")
        XCTAssertTrue(script.contains(#"start --name "$1" --tags "$2" --disconnect-after-job"#), script)
        XCTAssertTrue(script.contains("'kinhin-1-r1' 'queue=kinhin,os=macos'"))
        XCTAssertTrue(script.contains("'kinhin-1-r2' 'queue=kinhin,os=macos'"))
        XCTAssertTrue(script.contains("umask 077"))
        XCTAssertTrue(script.contains(#"BUILDKITE_AGENT_TOKEN="$(cat token)""#))
        XCTAssertTrue(script.contains("rm -f token"), "the token file is deleted once the agent has read it")
        // The token only reaches the agents through their private files.
        XCTAssertEqual(script.components(separatedBy: "bkct-secret").count, 3)
        XCTAssertTrue(script.contains("echo \"2 buildkite agent(s) started\""))
    }

    func testPersistentPoolsKeepTheirAgents() {
        let script = RunnerBootstrap.buildkiteRegistrationScript(
            token: "t", tags: ["queue=kinhin"], runnerNames: ["kinhin-1"], ephemeral: false,
            binary: "bk", baseDir: "/tmp/bk")
        XCTAssertFalse(script.contains("--disconnect-after-job"))
    }

    func testPoolLabelsAddOnlyNewKeyValueTags() {
        XCTAssertEqual(
            RunnerBootstrap.buildkiteTags(
                accountLabels: ["queue=kinhin"], poolLabels: ["macos", "queue=other", "runtime=docker"]),
            ["queue=kinhin", "runtime=docker"],
            "the account's queue wins; GitHub-style labels mean nothing to Buildkite")
        XCTAssertEqual(
            RunnerBootstrap.buildkiteTags(accountLabels: ["queue=kinhin"], poolLabels: nil), ["queue=kinhin"])
    }

    func testEachRuntimeUsesItsOwnAgentPaths() async throws {
        let tart = try await TartRuntime(tart: FakeTart(), bootTimeout: { 30 }).registrationScript(
            forge: forge(), token: "bkct-secret", runnerTokens: [:], name: "kinhin-1", runnerCount: 1, route: route,
            labels: nil)
        XCTAssertTrue(tart.contains("\"$HOME/buildkite-agent/buildkite-agent\""), tart)

        let docker = try await DockerRuntime(shell: FakeShell(), image: "img", cpus: 2, memoryGB: 4)
            .registrationScript(
                forge: forge(), token: "bkct-secret", runnerTokens: [:], name: "kinhin-1", runnerCount: 1,
                route: route, labels: nil)
        XCTAssertTrue(docker.contains("/opt/buildkite-agent/buildkite-agent"), docker)

        let agentDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let host = try await HostRuntime(shell: FakeShell(), agentDir: agentDir).registrationScript(
            forge: forge(), token: "bkct-secret", runnerTokens: [:], name: "kinhin-1", runnerCount: 1, route: route,
            labels: nil)
        XCTAssertTrue(host.contains(agentDir.appendingPathComponent("buildkite-agent").path), host)
        XCTAssertTrue(host.contains("host-instances/kinhin-1"), "agents live in the scrubbed instance dir")
    }
}
