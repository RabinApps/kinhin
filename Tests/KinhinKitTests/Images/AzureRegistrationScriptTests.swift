import XCTest

@testable import KinhinKit
@testable import KinhinTestSupport

/// The single-job Azure Pipelines agent bootstrap on each runtime.
final class AzureRegistrationScriptTests: XCTestCase {
    private let route = RepoRoute(repo: "acme", image: "img", ephemeral: true, bootTimeout: 30)

    private func forge() -> AzureDevOpsForge {
        let credentials = AzureDevOpsCredentials(
            token: "pat-secret", scope: "Mac Fleet", instance: "https://dev.azure.com/acme")
        return AzureDevOpsForge(
            credentials: ForgeCredentials(
                forge: .azuredevops, token: "pat-secret", scope: "Mac Fleet", instance: "https://dev.azure.com/acme"),
            labels: ["kinhin"], client: AzureDevOpsClient(credentials: credentials),
            pool: AzureDevOpsPool(id: 12, name: "Mac Fleet"))
    }

    func testEachAgentRegistersRunsOneJobAndRemovesItself() {
        let script = RunnerBootstrap.azureRegistrationScript(
            organization: "https://dev.azure.com/acme", token: "pat-secret", pool: "Mac Fleet",
            runnerNames: ["kinhin-1-r1", "kinhin-1-r2"], capabilities: ["kinhin=true"],
            template: "\"$HOME/azure-agent\"", baseDir: "\"$HOME/azure-agents\"", copy: .apfsClone)
        XCTAssertTrue(script.contains("cp -cR \"$HOME/azure-agent\" \"$HOME/azure-agents\"/'kinhin-1-r1'"), script)
        XCTAssertTrue(script.contains("./config.sh --unattended --url \"$1\" --auth pat --pool \"$2\" --agent \"$3\""))
        XCTAssertTrue(script.contains("./run.sh --once"))
        XCTAssertTrue(script.contains("./config.sh remove --unattended --auth pat"), "the agent deregisters itself")
        XCTAssertTrue(script.contains("export 'kinhin=true'"), "labels are advertised as capabilities")
        XCTAssertTrue(script.contains("'https://dev.azure.com/acme' 'Mac Fleet' 'kinhin-1-r2'"))
        XCTAssertTrue(script.contains(#"VSTS_AGENT_INPUT_TOKEN="$(cat .pat)""#))
        XCTAssertTrue(script.contains("umask 077"))
        // The PAT only reaches the agents through their private files.
        XCTAssertEqual(script.components(separatedBy: "pat-secret").count, 3)
    }

    /// Tart VMs can be macOS or Linux guests: the copy tries the APFS clone
    /// and falls back to a plain copy (wiping the partial target first).
    func testTheVMCopyFallsBackFromAPFSToAPlainCopy() {
        let script = RunnerBootstrap.azureRegistrationScript(
            organization: "https://dev.azure.com/acme", token: "pat-secret", pool: "Mac Fleet",
            runnerNames: ["kinhin-1"], capabilities: ["kinhin=true"],
            template: "\"$HOME/azure-agent\"", baseDir: "\"$HOME/azure-agents\"", copy: .vmGuest)
        XCTAssertTrue(script.contains(#"if ! cp -cR "$HOME/azure-agent" "$HOME/azure-agents"/'kinhin-1'"#), script)
        XCTAssertTrue(
            script.contains("rm -rf \"$HOME/azure-agents\"/'kinhin-1'"), "a partial clone is wiped before the fallback")
        XCTAssertTrue(script.contains(#"cp -a "$HOME/azure-agent" "$HOME/azure-agents"/'kinhin-1'"#), script)
    }

    /// The digest comes from the release notes' download table; this runs
    /// the extraction against a sample of it (no network).
    func testDigestIsReadFromTheReleaseNotesTable() throws {
        let command = RunnerBootstrap.azureAgentDigestCommand(version: "5.279.0", platform: "osx-arm64")
        let body =
            "| macOS x64 | [vsts-agent-osx-x64-5.279.0.tar.gz](https://x/vsts-agent-osx-x64-5.279.0.tar.gz) | "
            + String(repeating: "a", count: 64) + " |\n"
            + "| macOS ARM64 | [vsts-agent-osx-arm64-5.279.0.tar.gz](https://x/vsts-agent-osx-arm64-5.279.0.tar.gz) | "
            + String(repeating: "b", count: 64) + " |\n"
        let pipeline = try XCTUnwrap(command.range(of: "| grep").map { String(command[$0.lowerBound...]) })
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = ["-c", "printf '%s' \(RunnerBootstrap.shellQuote(body)) " + pipeline]
        let output = Pipe()
        process.standardOutput = output
        try process.run()
        process.waitUntilExit()
        let digest = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        XCTAssertEqual(digest.trimmingCharacters(in: .whitespacesAndNewlines), String(repeating: "b", count: 64))
    }

    func testEachRuntimeCopiesTheAgentItsOwnWay() async throws {
        let tart = try await TartRuntime(tart: FakeTart(), bootTimeout: { 30 }).registrationScript(
            forge: forge(), token: "pat-secret", runnerTokens: [:], name: "kinhin-1", runnerCount: 1, route: route,
            labels: nil)
        XCTAssertTrue(tart.contains("cp -cR \"$HOME/azure-agent\""), tart)
        XCTAssertTrue(tart.contains("cp -a"), "a Linux guest gets the fallback copy", )

        let docker = try await DockerRuntime(shell: FakeShell(), image: "img", cpus: 2, memoryGB: 4)
            .registrationScript(
                forge: forge(), token: "pat-secret", runnerTokens: [:], name: "kinhin-1", runnerCount: 1,
                route: route, labels: nil)
        XCTAssertTrue(docker.contains("cp -a /opt/azure-agent /opt/azure-agents/'kinhin-1'"), docker)
        XCTAssertTrue(docker.contains("export 'AGENT_ALLOW_RUNASROOT=1'"), "containers run the agent as root")

        let agentDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let host = try await HostRuntime(shell: FakeShell(), agentDir: agentDir).registrationScript(
            forge: forge(), token: "pat-secret", runnerTokens: [:], name: "kinhin-1", runnerCount: 1, route: route,
            labels: nil)
        XCTAssertTrue(host.contains(agentDir.appendingPathComponent("azure-agent").path), host)
        XCTAssertTrue(host.contains("host-instances/kinhin-1"), "agents live in the scrubbed instance dir")
    }
}
