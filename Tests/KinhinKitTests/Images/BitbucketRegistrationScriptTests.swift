import XCTest

@testable import KinhinKit
@testable import KinhinTestSupport

/// The Bitbucket runner bootstrap on each runtime. The registration script is executed under `/bin/bash` against a
/// stub `runner.sh` that records its argv, so these tests pin what the runner is actually started with (the live
/// Gitea/Forgejo runs found text-only assertions had pinned a double-quoted command that never ran).
final class BitbucketRegistrationScriptTests: XCTestCase {
    private let route = RepoRoute(repo: "acme", image: "img", ephemeral: true, bootTimeout: 30)
    private var scratch: URL!

    override func setUpWithError() throws {
        scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("bb-script-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
    }

    override func tearDown() {
        // Stub runners are `sleep` processes; stop whatever the test left running.
        let pids = (try? FileManager.default.subpathsOfDirectory(atPath: scratch.path)) ?? []
        for relative in pids where relative.hasSuffix("runner.pid") {
            if let text = try? String(contentsOf: scratch.appendingPathComponent(relative), encoding: .utf8),
                let pid = Int32(text.trimmingCharacters(in: .whitespacesAndNewlines))
            {
                kill(pid, SIGTERM)
            }
        }
        try? FileManager.default.removeItem(at: scratch)
        super.tearDown()
    }

    private func forge() -> BitbucketForge {
        let credentials = BitbucketCredentials(token: "bbtkn", scope: "acme")
        return BitbucketForge(
            credentials: ForgeCredentials(forge: .bitbucket, token: "bbtkn", scope: "acme"),
            labels: ["self.hosted", "macos", "kinhin"],
            client: BitbucketClient(credentials: credentials),
            scope: .workspace("acme"), workspaceUUID: "{ws-1}", repositoryUUID: nil, listTTL: 0)
    }

    // MARK: - Running the script

    private struct Outcome {
        let status: Int32
        let output: String
    }

    /// Runs `script` under `/bin/bash` with `KTEST_HOME` set to the scratch directory.
    private func run(_ script: String) throws -> Outcome {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = ["-c", script]
        var environment = ProcessInfo.processInfo.environment
        environment["KTEST_HOME"] = scratch.path
        process.environment = environment
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return Outcome(status: process.terminationStatus, output: String(decoding: data, as: UTF8.self))
    }

    /// A stub `runner.sh` that records one argv entry per line into `argv` in its working directory, then stays alive.
    private func writeStubRunner(_ body: String? = nil, at name: String = "runner.sh") throws -> URL {
        let url = scratch.appendingPathComponent(name)
        let script =
            body
                ?? """
                #!/bin/bash
                printf '%s\\n' "$@" > argv
                exec sleep 30
                """
        try script.write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        return url
    }

    private func recordedArgv(runner: String, timeout: TimeInterval = 5) throws -> [String] {
        let file = scratch.appendingPathComponent("runners/\(runner)/argv")
        let deadline = Date().addingTimeInterval(timeout)
        while !FileManager.default.fileExists(atPath: file.path), Date() < deadline {
            Thread.sleep(forTimeInterval: 0.05)
        }
        let text = try String(contentsOf: file, encoding: .utf8)
        return text.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
    }

    private func value(after flag: String, in argv: [String]) -> String? {
        guard let index = argv.firstIndex(of: flag), index + 1 < argv.count else { return nil }
        return argv[index + 1]
    }

    // MARK: - Behaviour of the generated script

    /// The command word the Tart script passes is `"$HOME/…/runner.sh"` (already quoted for the shell). It was
    /// quoted a second time, so the runner was looked up under a literal `"$HOME/…"` path and never started.
    func testRunnerIsStartedFromAnAlreadyQuotedCommandWord() throws {
        _ = try writeStubRunner()
        let script = RunnerBootstrap.bitbucketRegistrationScript(
            runners: [("kinhin-1-r1", "{ws}||{r1}|cli-1|sec-1"), ("kinhin-1-r2", "{ws}||{r2}|cli-2|sec-2")],
            runtime: "macos", runnerCommand: #""$KTEST_HOME/runner.sh""#,
            baseDir: #""$KTEST_HOME/runners""#, startupGrace: 1)
        let outcome = try run(script)
        XCTAssertEqual(outcome.status, 0, outcome.output)
        XCTAssertTrue(outcome.output.contains("2 bitbucket runner(s) started"), outcome.output)

        let first = try recordedArgv(runner: "kinhin-1-r1")
        XCTAssertEqual(value(after: "--accountUuid", in: first), "{ws}")
        XCTAssertEqual(value(after: "--runnerUuid", in: first), "{r1}")
        XCTAssertEqual(value(after: "--OAuthClientId", in: first), "cli-1")
        XCTAssertEqual(value(after: "--OAuthClientSecret", in: first), "sec-1")
        XCTAssertEqual(value(after: "--runtime", in: first), "macos")
        XCTAssertEqual(
            value(after: "--workingDirectory", in: first),
            scratch.appendingPathComponent("runners/kinhin-1-r1/work").path)
        XCTAssertFalse(first.contains("--repositoryUuid"), "a workspace-scoped runner has no repository UUID")
        let second = try recordedArgv(runner: "kinhin-1-r2")
        XCTAssertEqual(value(after: "--runnerUuid", in: second), "{r2}", "each runner gets its own bundle")
    }

    /// The host runtime quotes the installed path itself (it lives under `Application Support`).
    func testRunnerCommandWithASpaceInItsPathStarts() throws {
        let dir = scratch.appendingPathComponent("Application Support", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("runner.sh")
        try "#!/bin/bash\nprintf '%s\\n' \"$@\" > argv\nexec sleep 30\n".write(
            to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        let script = RunnerBootstrap.bitbucketRegistrationScript(
            runners: [("kinhin-1", "{ws}||{r}|cli|sec")], runtime: "macos",
            runnerCommand: RunnerBootstrap.shellQuote(url.path),
            baseDir: RunnerBootstrap.shellQuote(scratch.appendingPathComponent("runners").path), startupGrace: 1)
        let outcome = try run(script)
        XCTAssertEqual(outcome.status, 0, outcome.output)
        XCTAssertEqual(value(after: "--runtime", in: try recordedArgv(runner: "kinhin-1")), "macos")
    }

    /// `$REPOSITORY_UUID_FLAG` was never assigned, so repository-scoped runners dropped `--repositoryUuid`.
    func testRepositoryScopedRunnerCarriesItsRepositoryUUID() throws {
        _ = try writeStubRunner()
        let script = RunnerBootstrap.bitbucketRegistrationScript(
            runners: [("kinhin-1", "{ws}|{repo-1}|{r1}|cli-1|sec-1")], runtime: "linux-shell",
            runnerCommand: #""$KTEST_HOME/runner.sh""#, baseDir: #""$KTEST_HOME/runners""#, startupGrace: 1)
        XCTAssertEqual(try run(script).status, 0)
        let argv = try recordedArgv(runner: "kinhin-1")
        XCTAssertEqual(value(after: "--repositoryUuid", in: argv), "{repo-1}")
        XCTAssertEqual(value(after: "--runtime", in: argv), "linux-shell")
    }

    func testCredentialFileIsGoneOnceTheRunnerRead() throws {
        _ = try writeStubRunner()
        let script = RunnerBootstrap.bitbucketRegistrationScript(
            runners: [("kinhin-1", "{ws}||{r1}|cli-1|sec-1")], runtime: "macos",
            runnerCommand: #""$KTEST_HOME/runner.sh""#, baseDir: #""$KTEST_HOME/runners""#, startupGrace: 1)
        XCTAssertEqual(try run(script).status, 0)
        _ = try recordedArgv(runner: "kinhin-1")
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: scratch.appendingPathComponent("runners/kinhin-1/credentials").path),
            "job steps must not find the OAuth client secret on disk")
    }

    /// `auto` is resolved by the guest: Darwin -> macos, anything else -> linux-shell.
    func testAutoRuntimeIsResolvedByTheGuest() throws {
        _ = try writeStubRunner()
        let script = RunnerBootstrap.bitbucketRegistrationScript(
            runners: [("kinhin-1", "{ws}||{r1}|cli-1|sec-1")], runtime: "auto",
            runnerCommand: #""$KTEST_HOME/runner.sh""#, baseDir: #""$KTEST_HOME/runners""#, startupGrace: 1)
        XCTAssertEqual(try run(script).status, 0)
        #if os(macOS)
            let expected = "macos"
        #else
            let expected = "linux-shell"
        #endif
        XCTAssertEqual(value(after: "--runtime", in: try recordedArgv(runner: "kinhin-1")), expected)
    }

    /// A runner that dies at once (missing JDK, bad credentials) used to leave an exit-0 script.
    func testRunnerThatDiesAtStartFailsRegistrationWithItsLog() throws {
        _ = try writeStubRunner(
            """
            #!/bin/bash
            echo "java: command not found"
            exit 127
            """)
        let script = RunnerBootstrap.bitbucketRegistrationScript(
            runners: [("kinhin-1", "{ws}||{r1}|cli-1|sec-1")], runtime: "macos",
            runnerCommand: #""$KTEST_HOME/runner.sh""#, baseDir: #""$KTEST_HOME/runners""#, startupGrace: 1)
        let outcome = try run(script)
        XCTAssertEqual(outcome.status, 1, outcome.output)
        XCTAssertTrue(outcome.output.contains("java: command not found"), outcome.output)
        XCTAssertFalse(outcome.output.contains("started"), outcome.output)
    }

    /// The platform label was fixed when the runner was created: a guest of the other OS can never serve it.
    func testGuestOfTheOtherPlatformFailsRegistration() throws {
        _ = try writeStubRunner()
        #if os(macOS)
            let wrong = "linux.shell"
        #else
            let wrong = "macos"
        #endif
        let script = RunnerBootstrap.bitbucketRegistrationScript(
            runners: [("kinhin-1", "{ws}||{r1}|cli-1|sec-1")], runtime: "auto",
            runnerCommand: #""$KTEST_HOME/runner.sh""#, baseDir: #""$KTEST_HOME/runners""#,
            expectedPlatform: wrong, startupGrace: 1)
        let outcome = try run(script)
        XCTAssertEqual(outcome.status, 1, outcome.output)
        XCTAssertTrue(outcome.output.contains("add a matching label"), outcome.output)
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: scratch.appendingPathComponent("runners").path),
            "nothing is started on a guest that cannot serve the runners")
    }

    // MARK: - The installed wrapper

    /// macOS Temurin tarballs unpack to `Contents/Home`: the wrapper must point JAVA_HOME and PATH there.
    func testWrapperFindsTheMacOSJDKLayout() throws {
        let root = scratch.appendingPathComponent("bitbucket-runner", isDirectory: true)
        let bin = root.appendingPathComponent("bin", isDirectory: true)
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("jdk/Contents/Home/bin"), withIntermediateDirectories: true)
        let start = bin.appendingPathComponent("start.sh")
        try "#!/bin/bash\necho \"JAVA_HOME=$JAVA_HOME\"\necho \"ARGS=$*\"\n".write(
            to: start, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: start.path)

        let launcher = RunnerBootstrap.bitbucketLauncherScript(root: RunnerBootstrap.shellQuote(root.path))
        XCTAssertEqual(try run("cd \(RunnerBootstrap.shellQuote(root.path))\n\(launcher)").status, 0)
        let result = try run("\(RunnerBootstrap.shellQuote(root.appendingPathComponent("runner.sh").path)) --a 'b c'")
        XCTAssertEqual(result.status, 0, result.output)
        XCTAssertTrue(result.output.contains("JAVA_HOME=\(root.path)/jdk/Contents/Home"), result.output)
        XCTAssertTrue(result.output.contains("ARGS=--a b c"), result.output)
    }

    func testWrapperFindsTheLinuxJDKLayout() throws {
        let root = scratch.appendingPathComponent("bitbucket-runner", isDirectory: true)
        let bin = root.appendingPathComponent("bin", isDirectory: true)
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("jdk/bin"), withIntermediateDirectories: true)
        let start = bin.appendingPathComponent("start.sh")
        try "#!/bin/bash\necho \"JAVA_HOME=$JAVA_HOME\"\n".write(to: start, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: start.path)

        let launcher = RunnerBootstrap.bitbucketLauncherScript(root: RunnerBootstrap.shellQuote(root.path))
        XCTAssertEqual(try run("cd \(RunnerBootstrap.shellQuote(root.path))\n\(launcher)").status, 0)
        let result = try run(RunnerBootstrap.shellQuote(root.appendingPathComponent("runner.sh").path))
        XCTAssertTrue(result.output.contains("JAVA_HOME=\(root.path)/jdk\n"), result.output)
    }

    // MARK: - Per-runtime wiring

    func testEachRuntimeUsesItsOwnRunnerPaths() async throws {
        let runnerTokens = ["kinhin-1": "{ws-1}||{r-1}|cli-1|sec-1"]
        let tart = try await TartRuntime(tart: FakeTart(), bootTimeout: { 30 }).registrationScript(
            forge: forge(), token: "", runnerTokens: runnerTokens, name: "kinhin-1", runnerCount: 1,
            route: route, labels: nil)
        XCTAssertTrue(tart.contains(#""$HOME/bitbucket-runner/runner.sh""#), tart)
        XCTAssertTrue(tart.contains(#""$HOME/bitbucket-runners""#), tart)
        XCTAssertTrue(tart.contains("KINHIN_GUEST"), "a Tart guest is checked against the runner's platform label")

        let docker = try await DockerRuntime(shell: FakeShell(), image: "img", cpus: 2, memoryGB: 4)
            .registrationScript(
                forge: forge(), token: "", runnerTokens: runnerTokens, name: "kinhin-1", runnerCount: 1,
                route: route, labels: nil)
        XCTAssertTrue(docker.contains("/opt/bitbucket-runner/runner.sh"), docker)
        XCTAssertTrue(docker.contains("'linux-shell'"), docker)

        let agentDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let host = try await HostRuntime(shell: FakeShell(), agentDir: agentDir).registrationScript(
            forge: forge(), token: "", runnerTokens: runnerTokens, name: "kinhin-1", runnerCount: 1,
            route: route, labels: nil)
        XCTAssertTrue(host.contains(agentDir.appendingPathComponent("bitbucket-runner/runner.sh").path), host)
        XCTAssertTrue(host.contains("host-instances/kinhin-1"), "runners live in the scrubbed instance dir")
    }

    /// The pool's marker decides the platform the Tart guard expects: a container pool's labels name Linux.
    func testTartScriptExpectsTheLinuxPlatformWhenThePoolSaysLinux() async throws {
        let runnerTokens = ["kinhin-1": "{ws-1}||{r-1}|cli-1|sec-1"]
        let script = try await TartRuntime(tart: FakeTart(), bootTimeout: { 30 }).registrationScript(
            forge: forge(), token: "", runnerTokens: runnerTokens, name: "kinhin-1", runnerCount: 1,
            route: route, labels: ["self-hosted", "linux", "arm64"])
        XCTAssertTrue(script.contains(#"!= 'linux.shell' ]"#), script)
    }

    func testRunnerCountProducesOneRunnerPerName() throws {
        let runners = try RunnerBootstrap.bitbucketRunners(
            name: "kinhin-7", runnerCount: 2,
            tokens: [
                "kinhin-7-r1": "{ws}||{r1}|cli|sec1",
                "kinhin-7-r2": "{ws}||{r2}|cli|sec2",
            ])
        XCTAssertEqual(runners.map(\.name), ["kinhin-7-r1", "kinhin-7-r2"])
        XCTAssertThrowsError(
            try RunnerBootstrap.bitbucketRunners(name: "kinhin-7", runnerCount: 1, tokens: [:]),
            "a missing bundle is a registration failure, not an empty runner"
        )
    }

    // MARK: - Install scripts

    func testInstallScriptDownloadsThePinnedPackageAndJDK() {
        let script = RunnerBootstrap.bitbucketRunnerInstallScript(
            version: "6.0.8", jdkVersion: "25.0.4.1+1", jdkPlatform: "aarch64_mac")
        XCTAssertTrue(
            script.contains(
                "https://product-downloads.atlassian.com/software/bitbucket/pipelines/atlassian-bitbucket-pipelines-runner-6.0.8.tar.gz"
            ),
            script)
        XCTAssertTrue(script.contains("tar xzf runner.tar.gz"), script)
        XCTAssertTrue(script.contains("bin/start.sh"), "the package's launcher is the install marker")
        XCTAssertTrue(
            script.contains("releases/download/jdk-25.0.4.1+1/OpenJDK25U-jdk_aarch64_mac_hotspot_25.0.4.1_1.tar.gz"),
            script)
        XCTAssertTrue(script.contains(".sha256.txt"), "the JDK digest comes from Temurin's sidecar")
        XCTAssertTrue(
            script.contains(#"-x "$HOME/bitbucket-runner/jdk/Contents/Home/bin/java""#),
            "the macOS JDK nests under Contents/Home; checking jdk/bin/java re-downloaded it every install")
        XCTAssertTrue(script.contains("JAVA_HOME"), "the wrapper exports JAVA_HOME")
    }

    func testLinuxInstallScriptUsesTheOptLayoutAndTheContainersArchitecture() {
        let arm = RunnerBootstrap.linuxBitbucketRunnerInstallScript(version: "6.0.8", jdkVersion: "25.0.4.1+1")
        XCTAssertTrue(arm.contains("/opt/bitbucket-runner/bin/start.sh"), arm)
        XCTAssertTrue(arm.contains("OpenJDK25U-jdk_aarch64_linux_hotspot"), arm)
        let amd = RunnerBootstrap.linuxBitbucketRunnerInstallScript(
            version: "6.0.8", jdkVersion: "25.0.4.1+1", jdkPlatform: "x64_linux")
        XCTAssertTrue(amd.contains("OpenJDK25U-jdk_x64_linux_hotspot"), amd)
        XCTAssertFalse(amd.contains("aarch64_linux"), "an amd64 container must not get the aarch64 JDK")
    }

    func testContainerBakeUsesThePlatformsJDK() throws {
        let versions = RunnerVersionResolver.Versions(github: "2.337.0", gitea: "4.0.0")
        let script = RunnerAgentSpec.bitbucket.bake.container(versions, .amd64)
        XCTAssertTrue(script.contains("x64_linux"), script)
        XCTAssertFalse(script.contains("aarch64_linux"), script)
    }

    func testRunnerPackageDigestIsPinned() {
        XCTAssertEqual(
            RunnerVersionResolver.pinnedBitbucketRunnerDigests["6.0.8"]?.count, 64,
            "the pinned digest is a full SHA-256")
    }
}
