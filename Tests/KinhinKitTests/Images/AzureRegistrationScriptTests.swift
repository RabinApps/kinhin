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

    // MARK: - Behaviour (the script runs under /bin/bash against stub config.sh / run.sh)

    /// A throwaway agent template (`config.sh`, `run.sh`) whose stubs log what they were called with, and a base
    /// directory the generated script clones it into.
    private final class Harness {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("azure-" + UUID().uuidString)
        var template: URL { root.appendingPathComponent("template") }
        var base: URL { root.appendingPathComponent("agents") }
        var log: URL { root.appendingPathComponent("stub.log") }

        init() throws {
            try FileManager.default.createDirectory(at: template, withIntermediateDirectories: true)
            let config = """
                #!/bin/bash
                if [ "$1" = remove ]; then
                  echo "remove: $* token=${VSTS_AGENT_INPUT_TOKEN:+set}" >> "$STUB_LOG"
                  exit 0
                fi
                echo "config: $* token=${VSTS_AGENT_INPUT_TOKEN:+set} dir=$(basename "$PWD")" >> "$STUB_LOG"
                echo "env: kinhin_docker=${kinhin_docker-unset} evil=${evil-unset} root=${AGENT_ALLOW_RUNASROOT-unset}" \
                  >> "$STUB_LOG"
                if [ -n "${CONFIG_EXIT:-}" ]; then
                  echo "boom: registration refused"
                  exit "$CONFIG_EXIT"
                fi
                exit 0
                """
            let run = """
                #!/bin/bash
                echo "run: $* token=${VSTS_AGENT_INPUT_TOKEN:+set}" >> "$STUB_LOG"
                """
            for (name, body) in [("config.sh", config), ("run.sh", run)] {
                let url = template.appendingPathComponent(name)
                try body.write(to: url, atomically: true, encoding: .utf8)
                try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
            }
        }

        deinit { try? FileManager.default.removeItem(at: root) }

        struct Outcome {
            let status: Int32
            let stdout: String
            let stderr: String
        }

        func run(_ script: String, environment: [String: String] = [:]) throws -> Outcome {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/bash")
            process.arguments = ["-c", script]
            var env = ProcessInfo.processInfo.environment
            env["STUB_LOG"] = log.path
            for (key, value) in environment { env[key] = value }
            process.environment = env
            let out = Pipe()
            let err = Pipe()
            process.standardOutput = out
            process.standardError = err
            try process.run()
            let stdout = out.fileHandleForReading.readDataToEndOfFile()
            let stderr = err.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            return Outcome(
                status: process.terminationStatus, stdout: String(decoding: stdout, as: UTF8.self),
                stderr: String(decoding: stderr, as: UTF8.self))
        }

        /// The stub log once it holds `needle` `count` times (the backgrounded agent finishes after the script
        /// returns).
        func waitForLog(containing needle: String, count: Int = 1, timeout: TimeInterval = 10) -> String {
            let deadline = Date().addingTimeInterval(timeout)
            var text = ""
            repeat {
                text = (try? String(contentsOf: log, encoding: .utf8)) ?? ""
                if text.components(separatedBy: needle).count - 1 >= count { return text }
                Thread.sleep(forTimeInterval: 0.05)
            } while Date() < deadline
            return text
        }

        func script(
            runners: [String] = ["kinhin-1"], capabilities: [String] = ["kinhin=true"], ephemeral: Bool = true,
            extraEnvironment: [String] = [], token: String = "pat-secret"
        ) -> String {
            RunnerBootstrap.azureRegistrationScript(
                organization: "https://dev.azure.com/acme", token: token, pool: "Mac Fleet", runnerNames: runners,
                capabilities: capabilities, template: RunnerBootstrap.shellQuote(template.path),
                baseDir: RunnerBootstrap.shellQuote(base.path), copy: .archive, ephemeral: ephemeral,
                extraEnvironment: extraEnvironment)
        }
    }

    func testEachAgentRegistersRunsOneJobAndRemovesItself() throws {
        let harness = try Harness()
        let outcome = try harness.run(
            harness.script(runners: ["kinhin-1-r1", "kinhin-1-r2"], capabilities: ["kinhin_docker=true"]))
        XCTAssertEqual(outcome.status, 0, outcome.stderr)
        let log = harness.waitForLog(containing: "remove:", count: 2)
        let lines = log.split(separator: "\n").map(String.init)
        for runner in ["kinhin-1-r1", "kinhin-1-r2"] {
            XCTAssertTrue(
                lines.contains(
                    "config: --unattended --url https://dev.azure.com/acme --auth pat --pool Mac Fleet "
                        + "--agent \(runner) --replace --acceptTeeEula --work \(harness.base.path)/\(runner)/_work "
                        + "token=set dir=\(runner)"),
                log)
        }
        XCTAssertTrue(
            lines.contains("env: kinhin_docker=true evil=unset root=unset"), "capabilities are exported: \(log)")
        // The job and the removal both ran, once per agent, with `--once`.
        XCTAssertEqual(lines.filter { $0 == "run: --once token=" }.count, 2, log)
        XCTAssertEqual(lines.filter { $0 == "remove: remove --unattended --auth pat token=set" }.count, 2, log)
    }

    /// The point of registering in the foreground: a refused registration is an error of the script itself, with
    /// the agent's own output, and nothing is started.
    func testARegistrationFailureFailsTheScriptWithTheAgentLog() throws {
        let harness = try Harness()
        let outcome = try harness.run(harness.script(), environment: ["CONFIG_EXIT": "3"])
        XCTAssertEqual(outcome.status, 1)
        XCTAssertTrue(outcome.stderr.contains("failed to register (config.sh exit 3)"), outcome.stderr)
        XCTAssertTrue(outcome.stderr.contains("boom: registration refused"), "the agent's output is shown")
        XCTAssertFalse(outcome.stdout.contains("started"), "no success line")
        Thread.sleep(forTimeInterval: 0.3)
        let log = (try? String(contentsOf: harness.log, encoding: .utf8)) ?? ""
        XCTAssertFalse(log.contains("run:"), "a job must not start on an unregistered agent: \(log)")
        XCTAssertFalse(log.contains("remove:"), log)
        let pid = harness.base.appendingPathComponent("kinhin-1/agent.pid").path
        XCTAssertFalse(FileManager.default.fileExists(atPath: pid))
    }

    /// `ephemeral: false` must not pass `--once`: the agent keeps taking jobs.
    func testANonEphemeralAgentTakesJobsUntilStopped() throws {
        let harness = try Harness()
        let outcome = try harness.run(harness.script(ephemeral: false))
        XCTAssertEqual(outcome.status, 0, outcome.stderr)
        let log = harness.waitForLog(containing: "remove:")
        XCTAssertTrue(log.contains("run:  token=\n"), "plain run.sh: \(log)")
        XCTAssertFalse(log.contains("--once"), log)
    }

    /// The PAT reaches config.sh and the removal only through the environment of that one command: no file in the
    /// agent directory (the log included) ever holds it.
    func testThePATIsOnlyEverInTheEnvironmentOfTheCommandsThatNeedIt() throws {
        let harness = try Harness()
        let outcome = try harness.run(harness.script(token: "pat-secret-value"))
        XCTAssertEqual(outcome.status, 0, outcome.stderr)
        let log = harness.waitForLog(containing: "remove:")
        XCTAssertTrue(log.contains("run: --once token=\n"), "run.sh and the jobs inherit no PAT: \(log)")
        let files = try XCTUnwrap(FileManager.default.enumerator(at: harness.base, includingPropertiesForKeys: nil))
        for case let file as URL in files where !file.hasDirectoryPath {
            let content = (try? String(contentsOf: file, encoding: .utf8)) ?? ""
            XCTAssertFalse(content.contains("pat-secret-value"), "\(file.lastPathComponent) holds the PAT")
        }
        XCTAssertFalse(outcome.stdout.contains("pat-secret-value"))
        XCTAssertFalse(outcome.stderr.contains("pat-secret-value"))
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

    /// A capability value must stay one literal value: it is single-quoted into an `export`, never evaluated.
    func testCapabilityValuesCannotBreakOutOfTheExport() throws {
        let harness = try Harness()
        let marker = harness.root.appendingPathComponent("pwned").path
        let hostile = "evil=1'; touch \(marker); echo '$(touch \(marker))"
        let outcome = try harness.run(harness.script(capabilities: [hostile]))
        XCTAssertEqual(outcome.status, 0, outcome.stderr)
        let log = harness.waitForLog(containing: "remove:")
        XCTAssertFalse(FileManager.default.fileExists(atPath: marker), "the value was executed")
        XCTAssertTrue(log.contains("evil=1'; touch \(marker); echo '$(touch \(marker))"), log)
    }

    func testRuntimeEnvironmentIsExportedBeforeRegistration() throws {
        let harness = try Harness()
        let outcome = try harness.run(harness.script(extraEnvironment: ["AGENT_ALLOW_RUNASROOT=1"]))
        XCTAssertEqual(outcome.status, 0, outcome.stderr)
        let log = harness.waitForLog(containing: "remove:")
        XCTAssertTrue(log.contains("root=1"), log)
    }

    func testLabelValuesWithControlCharactersAreInvalid() {
        XCTAssertTrue(AzureDevOpsCredentials.isValidLabel("xcode=16.2 beta"))
        XCTAssertFalse(AzureDevOpsCredentials.isValidLabel("xcode=16\nINJECT=1"))
        XCTAssertFalse(AzureDevOpsCredentials.isValidLabel("xcode=16\u{0}"))
    }
}
