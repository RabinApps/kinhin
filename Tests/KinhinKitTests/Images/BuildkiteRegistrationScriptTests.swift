import XCTest

@testable import KinhinKit
@testable import KinhinTestSupport

/// The single-job Buildkite agent bootstrap on each runtime. The scripts are
/// executed under /bin/bash against a stub `buildkite-agent`.
final class BuildkiteRegistrationScriptTests: XCTestCase {
    private let route = RepoRoute(repo: "acme", image: "img", ephemeral: true, bootTimeout: 30)
    private var workDir: URL!

    override func setUpWithError() throws {
        workDir = FileManager.default.temporaryDirectory.appendingPathComponent("bk-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
    }

    override func tearDown() {
        // Stop any stub agents a test left running.
        if let pids = FileManager.default.enumerator(atPath: workDir.path) {
            for case let path as String in pids where path.hasSuffix("agent.pid") {
                if let text = try? String(contentsOf: workDir.appendingPathComponent(path), encoding: .utf8),
                    let pid = Int32(text.trimmingCharacters(in: .whitespacesAndNewlines))
                {
                    kill(pid, SIGKILL)
                }
            }
        }
        try? FileManager.default.removeItem(at: workDir)
        super.tearDown()
    }

    private func forge() -> BuildkiteForge {
        BuildkiteForge(
            credentials: ForgeCredentials(forge: .buildkite, token: "bkua", scope: "acme/default"),
            labels: ["queue=kinhin"],
            client: BuildkiteClient(credentials: BuildkiteCredentials(token: "bkua", scope: "acme/default")),
            cluster: BuildkiteCluster(id: "c-1", name: "default"), agentToken: "bkct-secret")
    }

    // MARK: - Harness

    /// A stub agent: records its argv and the token it was handed, then
    /// either stays alive (`body` = "exec sleep 60") or fails/finishes.
    private func stubAgent(_ body: String) throws -> URL {
        let path = workDir.appendingPathComponent("buildkite-agent")
        let script = """
            #!/bin/bash
            echo "$@" > "$PWD/argv"
            echo "${BUILDKITE_AGENT_TOKEN:-unset}" > "$PWD/token-seen"
            \(body)
            """
        try script.write(to: path, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: path.path)
        return path
    }

    private func run(_ script: String) async throws -> ShellResult {
        let file = workDir.appendingPathComponent("register.sh")
        try script.write(to: file, atomically: true, encoding: .utf8)
        return try await Shell().run(["/usr/bin/env", "-i", "PATH=/usr/bin:/bin", "/bin/bash", file.path])
    }

    private func agentDir(_ name: String) -> URL {
        workDir.appendingPathComponent("agents").appendingPathComponent(name)
    }

    private func read(_ name: String, _ file: String) -> String {
        (try? String(contentsOf: agentDir(name).appendingPathComponent(file), encoding: .utf8)) ?? ""
    }

    private func script(
        names: [String], tags: [String] = ["queue=kinhin", "os=macos"], ephemeral: Bool = true,
        token: String = "bkct-secret"
    ) throws -> String {
        let binary = workDir.appendingPathComponent("buildkite-agent").path
        return RunnerBootstrap.buildkiteRegistrationScript(
            token: token, tags: tags, runnerNames: names, ephemeral: ephemeral,
            binary: RunnerBootstrap.shellQuote(binary),
            baseDir: RunnerBootstrap.shellQuote(workDir.appendingPathComponent("agents").path), settleSeconds: 1)
    }

    // MARK: - Registration

    func testAgentsStartOneJobEachWithTheirTokenInTheEnvironment() async throws {
        _ = try stubAgent("exec sleep 60")
        let result = try await run(script(names: ["kinhin-1-r1", "kinhin-1-r2"]))
        XCTAssertTrue(result.succeeded, result.stdout + result.stderr)
        XCTAssertTrue(result.stdout.contains("2 buildkite agent(s) started"), result.stdout)
        for name in ["kinhin-1-r1", "kinhin-1-r2"] {
            XCTAssertEqual(
                read(name, "argv").trimmingCharacters(in: .whitespacesAndNewlines),
                "start --name \(name) --tags queue=kinhin,os=macos --disconnect-after-job --build-path "
                    + "\(agentDir(name).path)/builds --plugins-path \(agentDir(name).path)/plugins")
            XCTAssertEqual(read(name, "token-seen").trimmingCharacters(in: .whitespacesAndNewlines), "bkct-secret")
            XCTAssertFalse(
                FileManager.default.fileExists(atPath: agentDir(name).appendingPathComponent("token").path),
                "the token file is deleted once the agent has read it")
        }
    }

    func testPersistentPoolsKeepTheirAgents() async throws {
        _ = try stubAgent("exec sleep 60")
        let result = try await run(script(names: ["kinhin-1"], ephemeral: false))
        XCTAssertTrue(result.succeeded, result.stdout + result.stderr)
        XCTAssertFalse(read("kinhin-1", "argv").contains("--disconnect-after-job"))
    }

    func testAnAgentThatCannotRegisterFailsTheScriptWithItsLog() async throws {
        _ = try stubAgent("echo 'bad agent token: 401' >&2; exit 1")
        let result = try await run(script(names: ["kinhin-1"]))
        XCTAssertEqual(result.exitCode, 1)
        XCTAssertTrue(result.stdout.contains("exited immediately"), result.stdout)
        XCTAssertTrue(result.stdout.contains("bad agent token: 401"), "the agent's own log is shown: \(result.stdout)")
        XCTAssertFalse(result.stdout.contains("started"))
    }

    func testOneFailedAgentStopsTheOthers() async throws {
        // The second agent fails; the first would live on.
        _ = try stubAgent(
            """
            case "$*" in *kinhin-1-r2*) echo 'unknown queue' >&2; exit 3 ;; esac
            exec sleep 60
            """)
        let result = try await run(script(names: ["kinhin-1-r1", "kinhin-1-r2"]))
        XCTAssertEqual(result.exitCode, 1)
        XCTAssertTrue(result.stdout.contains("unknown queue"), result.stdout)
        let pid = try XCTUnwrap(
            Int32(read("kinhin-1-r1", "agent.pid").trimmingCharacters(in: .whitespacesAndNewlines)))
        try await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertNotEqual(kill(pid, 0), 0, "the healthy agent was stopped with the failed registration")
    }

    func testAnAgentThatAlreadyFinishedItsJobIsNotAFailure() async throws {
        _ = try stubAgent("exit 0")
        let result = try await run(script(names: ["kinhin-1"]))
        XCTAssertTrue(result.succeeded, result.stdout + result.stderr)
    }

    // MARK: - Tags

    func testPoolLabelsAddOnlyNewKeyValueTags() {
        XCTAssertEqual(
            RunnerBootstrap.buildkiteTags(
                accountLabels: ["queue=kinhin"], poolLabels: ["macos", "queue=other", "runtime=docker"]),
            ["queue=kinhin", "runtime=docker"],
            "the account's queue wins; GitHub-style labels mean nothing to Buildkite")
        XCTAssertEqual(
            RunnerBootstrap.buildkiteTags(accountLabels: ["queue=kinhin"], poolLabels: nil), ["queue=kinhin"])
    }

    func testRuntimeMarkersTravelAsARuntimeTag() {
        XCTAssertEqual(
            RunnerBootstrap.buildkiteTags(accountLabels: ["queue=kinhin"], poolLabels: ["macos", "kinhin-docker"]),
            ["queue=kinhin", "kinhin-runtime=docker"])
        XCTAssertEqual(
            RunnerBootstrap.buildkiteTags(accountLabels: ["queue=kinhin"], poolLabels: ["kinhin-container"]),
            ["queue=kinhin", "kinhin-runtime=container"])
        XCTAssertEqual(
            RunnerBootstrap.buildkiteTags(accountLabels: ["queue=kinhin"], poolLabels: ["kinhin-host"]),
            ["queue=kinhin", "kinhin-runtime=host"])
    }

    // MARK: - Install

    private func tarball(member: String, in dir: URL) async throws {
        let src = dir.appendingPathComponent("src")
        try FileManager.default.createDirectory(at: src, withIntermediateDirectories: true)
        try "#!/bin/sh\n".write(to: src.appendingPathComponent(member), atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755], ofItemAtPath: src.appendingPathComponent(member).path)
        let result = try await Shell().run(
            ["/usr/bin/tar", "czf", dir.appendingPathComponent("agent.tar.gz").path, "-C", src.path, member])
        XCTAssertTrue(result.succeeded, result.stderr)
        try FileManager.default.removeItem(at: src)
    }

    func testExtractionDoesNotDependOnTheArchivesMemberPrefix() async throws {
        let dir = workDir.appendingPathComponent("install")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try await tarball(member: "buildkite-agent", in: dir)
        let result = try await run(
            "set -euo pipefail\ncd '\(dir.path)'\n"
                + RunnerBootstrap.buildkiteAgentExtractScript(archive: "agent.tar.gz"))
        XCTAssertTrue(result.succeeded, result.stdout + result.stderr)
        XCTAssertTrue(FileManager.default.isExecutableFile(atPath: dir.appendingPathComponent("buildkite-agent").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.appendingPathComponent("agent.tar.gz").path))
    }

    func testAnArchiveWithoutTheBinaryFailsTheInstall() async throws {
        let dir = workDir.appendingPathComponent("install")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try await tarball(member: "something-else", in: dir)
        let result = try await run(
            "set -euo pipefail\ncd '\(dir.path)'\n"
                + RunnerBootstrap.buildkiteAgentExtractScript(archive: "agent.tar.gz"))
        XCTAssertEqual(result.exitCode, 1)
        XCTAssertTrue(result.stderr.contains("missing from the release archive"), result.stderr)
    }

    // MARK: - Runtimes

    func testEachRuntimeUsesItsOwnAgentPaths() async throws {
        let tart = try await TartRuntime(tart: FakeTart(), bootTimeout: { 30 }).registrationScript(
            forge: forge(), token: "bkct-secret", runnerTokens: [:], name: "kinhin-1", runnerCount: 1, route: route,
            labels: nil)
        XCTAssertTrue(tart.contains("\"$HOME/buildkite-agent/buildkite-agent\""), tart)

        let docker = try await DockerRuntime(shell: FakeShell(), image: "img", cpus: 2, memoryGB: 4)
            .registrationScript(
                forge: forge(), token: "bkct-secret", runnerTokens: [:], name: "kinhin-1", runnerCount: 1,
                route: route, labels: ["kinhin-docker"])
        XCTAssertTrue(docker.contains("/opt/buildkite-agent/buildkite-agent"), docker)
        XCTAssertTrue(docker.contains("queue=kinhin,kinhin-runtime=docker"), "the marker is a tag: \(docker)")

        let agentDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let host = try await HostRuntime(shell: FakeShell(), agentDir: agentDir).registrationScript(
            forge: forge(), token: "bkct-secret", runnerTokens: [:], name: "kinhin-1", runnerCount: 1, route: route,
            labels: nil)
        XCTAssertTrue(host.contains(agentDir.appendingPathComponent("buildkite-agent").path), host)
        XCTAssertTrue(host.contains("host-instances/kinhin-1"), "agents live in the scrubbed instance dir")
    }
}
