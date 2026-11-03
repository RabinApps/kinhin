import XCTest

@testable import KinhinKit
@testable import KinhinTestSupport

/// A Docker runner's dockerd pointed at the Docker Hub cache: at registration, before dockerd starts, the runtime
/// asks the cache for its address, checks the runner reaches it, reads the image's daemon.json and writes it back with
/// the mirror merged in. Every failure on that path is skipped (the runner registers and pulls from Docker Hub); only
/// cancellation propagates. Pools without Docker or with `cache: false` do none of it.
final class AppleContainerDockerCacheTests: XCTestCase {
    private let bin = "/usr/local/bin/container"
    private var dataDirectory: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("docker-cache-\(UUID().uuidString)")
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        dataDirectory = dir
    }

    private static let githubImageFile = #"{"mtu": 1280, "registry-mirrors": ["http://192.168.64.1:5055"]}"#

    private static let runningCache = ShellResult(
        exitCode: 0,
        stdout: #"[{"status":{"state":"running","networks":[{"ipv4Address":"192.168.64.3/24"}]}}]"#, stderr: "")

    private static func probeAnswer(_ daemonJSON: String, noise: String = "") -> ShellResult {
        ShellResult(
            exitCode: 0, stdout: noise + AppleContainerRuntime.daemonJSONMarker + "\n" + daemonJSON + "\n",
            stderr: "")
    }

    /// A Docker runtime on `shell` that uses a cache on the same shell.
    private func makeRuntime(_ shell: ShellRunning, docker: Bool = true) -> AppleContainerRuntime {
        var runtime = AppleContainerRuntime(shell: shell, image: "kinhin-ci-linux", docker: docker, binPath: bin)
        runtime.registryCache = DockerRegistryCache(
            shell: shell, binPath: bin, dataDirectory: dataDirectory, addressPolls: 2, pollInterval: .milliseconds(1))
        return runtime
    }

    /// A shell whose cache runs at 192.168.64.3 and whose runner prints `probe` for the cache probe.
    private func fakeShell(probe: ShellResult) -> FakeShell {
        let shell = FakeShell()
        shell.scriptedResponses = [
            ScriptedResponse(whenContains: "inspect", Self.runningCache),
            ScriptedResponse(whenContainsAll: ["exec", AppleContainerRuntime.daemonJSONMarker], probe),
        ]
        return shell
    }

    private func registrationScript(_ runtime: AppleContainerRuntime) async throws -> String {
        let github = GitHubForge(
            credentials: .github(token: "t", scope: "acme/widgets"), labels: ["kinhin"], client: FakeGitHub())
        return try await runtime.registrationScript(
            forge: github, token: "RT", name: "kinhin-1", runnerCount: 1, route: makeRoute(), labels: nil)
    }

    private func makeRoute() -> RepoRoute {
        RepoRoute(repo: "acme/widgets", image: "kinhin-ci-linux", ephemeral: true, bootTimeout: 30)
    }

    private func object(_ json: String?) throws -> [String: Any] {
        let data = Data(try XCTUnwrap(json).utf8)
        return try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    // MARK: - The happy path

    func testARunnerGetsTheImagesDaemonJSONWithTheCachesMirror() async throws {
        let shell = fakeShell(probe: Self.probeAnswer(Self.githubImageFile, noise: "Welcome to Ubuntu\n"))
        let json = try await makeRuntime(shell).dockerDaemonJSON(for: "kinhin-1")
        let settings = try object(json)
        XCTAssertEqual(
            settings["registry-mirrors"] as? [String], ["http://192.168.64.3:5000"], "the stale one replaced")
        XCTAssertEqual(settings["mtu"] as? Int, 1280, "the image's other settings kept")

        let exec = try XCTUnwrap(shell.calls.first { $0.contains("exec") })
        XCTAssertEqual(Array(exec.prefix(6)), [bin, "exec", "-i", "kinhin-1", "/bin/bash", "-ls"])
        XCTAssertEqual(exec.last, AppleContainerRuntime.cacheProbeScript(address: "192.168.64.3"))
    }

    func testTheRegistrationScriptWritesItBeforeDockerdStarts() async throws {
        let shell = fakeShell(probe: Self.probeAnswer(Self.githubImageFile))
        let script = try await registrationScript(makeRuntime(shell))
        let write = try XCTUnwrap(
            script.range(of: "mv -f /etc/docker/daemon.json.kinhin-new /etc/docker/daemon.json"))
        let dockerd = try XCTUnwrap(script.range(of: "setsid nohup dockerd"))
        let register = try XCTUnwrap(script.range(of: "./config.sh --url"))
        XCTAssertLessThan(write.upperBound, dockerd.lowerBound, "dockerd starts with the merged file")
        XCTAssertLessThan(dockerd.upperBound, register.lowerBound)
        XCTAssertTrue(script.contains("\"http://192.168.64.3:5000\""), script)
        XCTAssertTrue(script.hasPrefix("# Docker Hub cache (container.docker)"), script)

        let syntax = try await Shell().run(["/bin/bash", "-n", "-c", script], cwd: nil, timeout: 10)
        XCTAssertTrue(syntax.succeeded, "composed registration script: \(syntax.stderr)")
    }

    func testTheWriteLeavesExactlyTheMergedJSONOnDisk() async throws {
        guard
            case .merged(let json) = DockerDaemonConfig.merging(mirror: "http://10.0.0.9:5000", into: "{\"mtu\": 1280}")
        else { return XCTFail("expected a merge") }
        let target = dataDirectory.appendingPathComponent("etc/docker", isDirectory: true)
        let script = RunnerBootstrap.linuxDockerDaemonConfigScript(json: json)
            .replacingOccurrences(of: "/etc/docker", with: target.path)
        let result = try await Shell().run(["/bin/bash", "-c", script], cwd: nil, timeout: 10)
        XCTAssertTrue(result.succeeded, result.stderr)
        let written = try String(contentsOf: target.appendingPathComponent("daemon.json"), encoding: .utf8)
        XCTAssertEqual(written, json + "\n")
    }

    func testAFailedWriteOnlyWarns() async throws {
        let script = RunnerBootstrap.linuxDockerDaemonConfigScript(json: "{}")
            .replacingOccurrences(of: "/etc/docker", with: "/dev/null/kinhin")
        let result = try await Shell().run(["/bin/bash", "-c", script + "\necho next"], cwd: nil, timeout: 10)
        XCTAssertTrue(result.stderr.contains("kinhin: warning: could not write"), result.stderr)
        XCTAssertTrue(result.stdout.contains("next"), "the script goes on to start dockerd")
    }

    func testAFailedWriteLeavesTheImagesFileAsItWas() async throws {
        let target = dataDirectory.appendingPathComponent("etc/docker", isDirectory: true)
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        let original = "{\"mtu\": 1280}\n"
        try original.write(to: target.appendingPathComponent("daemon.json"), atomically: true, encoding: .utf8)
        // A directory where the new file goes makes the write fail after the old file was already in place.
        try FileManager.default.createDirectory(
            at: target.appendingPathComponent("daemon.json.kinhin-new"), withIntermediateDirectories: true)
        let script = RunnerBootstrap.linuxDockerDaemonConfigScript(json: "{\"registry-mirrors\": []}")
            .replacingOccurrences(of: "/etc/docker", with: target.path)
        let result = try await Shell().run(["/bin/bash", "-c", script + "\necho next"], cwd: nil, timeout: 10)
        XCTAssertTrue(result.stderr.contains("kinhin: warning: could not write"), result.stderr)
        XCTAssertTrue(result.stdout.contains("next"))
        let kept = try String(contentsOf: target.appendingPathComponent("daemon.json"), encoding: .utf8)
        XCTAssertEqual(kept, original, "never truncated: dockerd still starts with the image's settings")
        let leftover = target.appendingPathComponent("daemon.json.kinhin-new").path
        XCTAssertFalse(FileManager.default.fileExists(atPath: leftover), "the failed attempt is cleaned up")
    }

    // MARK: - Every failure is skipped

    private func assertSkipped(
        _ shell: FakeShell, execs: Int = 1, file: StaticString = #filePath, line: UInt = #line
    ) async throws {
        let runtime = makeRuntime(shell)
        let json = try await runtime.dockerDaemonJSON(for: "kinhin-1")
        XCTAssertNil(json, file: file, line: line)
        XCTAssertEqual(shell.calls.filter { $0.contains("exec") }.count, execs, file: file, line: line)
        let script = try await registrationScript(runtime)
        XCTAssertFalse(
            script.contains("/etc/docker/daemon.json"), "the image's file is left as it is", file: file, line: line)
        XCTAssertTrue(
            script.hasPrefix(RunnerBootstrap.linuxDockerDaemonScript()), "dockerd still starts", file: file, line: line)
    }

    func testACacheThatWillNotStartIsSkipped() async throws {
        let shell = FakeShell()
        shell.scriptedResponses = [
            ScriptedResponse(
                whenContains: "inspect", ShellResult(exitCode: 1, stdout: "", stderr: "XPC connection error"))
        ]
        try await assertSkipped(shell, execs: 0)
    }

    func testACacheThatFailsToRunIsSkipped() async throws {
        let shell = FakeShell()
        shell.scriptedResponses = [
            ScriptedResponse(
                whenContains: "inspect",
                ShellResult(exitCode: 1, stdout: "", stderr: "Error: container not found: registry-cache-kinhin")),
            ScriptedResponse(whenContains: "run", ShellResult(exitCode: 1, stdout: "", stderr: "pull failed")),
        ]
        try await assertSkipped(shell, execs: 0)
    }

    func testAnUnreachableCacheIsSkipped() async throws {
        let unreachable = ShellResult(exitCode: AppleContainerRuntime.cacheUnreachableExitCode, stdout: "", stderr: "")
        try await assertSkipped(fakeShell(probe: unreachable))
    }

    func testAnUnreadableDaemonJSONIsSkipped() async throws {
        let unreadable = ShellResult(exitCode: 1, stdout: "", stderr: "cat: /etc/docker/daemon.json: Permission denied")
        try await assertSkipped(fakeShell(probe: unreadable))
    }

    func testAnInvalidDaemonJSONIsSkipped() async throws {
        try await assertSkipped(fakeShell(probe: Self.probeAnswer("{\"mtu\": 1280,")))
    }

    func testOutputWithoutTheMarkerIsSkipped() async throws {
        try await assertSkipped(fakeShell(probe: ShellResult(exitCode: 0, stdout: "{}", stderr: "")))
    }

    func testAProbeThatCannotRunIsSkipped() async throws {
        let shell = FakeShell()
        shell.scriptedResponses = [
            ScriptedResponse(whenContains: "inspect", Self.runningCache),
            ScriptedResponse(whenContainsThrowing: AppleContainerRuntime.daemonJSONMarker, reason: "exec timed out"),
        ]
        try await assertSkipped(shell)
    }

    func testAnImageWithoutADaemonJSONGetsOneWithTheMirror() async throws {
        let json = try await makeRuntime(fakeShell(probe: Self.probeAnswer(""))).dockerDaemonJSON(for: "kinhin-1")
        XCTAssertEqual(try object(json)["registry-mirrors"] as? [String], ["http://192.168.64.3:5000"])
    }

    // MARK: - Cancellation propagates

    /// Throws `CancellationError` for any argv containing `needle`, like a shell whose task was cancelled mid-call.
    private struct CancellingShell: ShellRunning {
        let needle: String
        let fallback: FakeShell

        func run(_ argv: [String], cwd: URL?, timeout: TimeInterval) async throws -> ShellResult {
            if argv.contains(where: { $0.contains(needle) }) { throw CancellationError() }
            return try await fallback.run(argv, cwd: cwd, timeout: timeout)
        }

        func run(_ argv: [String], input: Data, cwd: URL?, timeout: TimeInterval) async throws -> ShellResult {
            try await run(argv + [String(decoding: input, as: UTF8.self)], cwd: cwd, timeout: timeout)
        }
    }

    func testCancellationWhileStartingTheCachePropagates() async {
        let shell = CancellingShell(needle: "inspect", fallback: FakeShell())
        do {
            _ = try await makeRuntime(shell).dockerDaemonJSON(for: "kinhin-1")
            XCTFail("expected CancellationError")
        } catch {
            XCTAssertTrue(error is CancellationError, "\(error)")
        }
    }

    func testCancellationWhileProbingPropagates() async {
        let shell = CancellingShell(
            needle: AppleContainerRuntime.daemonJSONMarker, fallback: fakeShell(probe: Self.probeAnswer("{}")))
        do {
            _ = try await registrationScript(makeRuntime(shell))
            XCTFail("expected CancellationError")
        } catch {
            XCTAssertTrue(error is CancellationError, "\(error)")
        }
    }

    // MARK: - Who uses the cache

    func testWithoutACacheOrWithoutDockerNothingIsAsked() async throws {
        let shell = FakeShell()
        let none = try await AppleContainerRuntime(shell: shell, docker: true, binPath: bin).dockerDaemonJSON(
            for: "kinhin-1")
        XCTAssertNil(none)
        let off = try await makeRuntime(shell, docker: false).dockerDaemonJSON(for: "kinhin-1")
        XCTAssertNil(off)
        XCTAssertEqual(shell.calls, [], "no cache lookup, no probe")
    }

    func testEachPoolGetsTheCacheOnlyWhenItUsesIt() {
        typealias Pool = KinhinConfig.ContainerConfig.Pool
        let cache = DockerRegistryCache(shell: FakeShell(), dataDirectory: dataDirectory)
        func runtime(_ pool: Pool) -> AppleContainerRuntime {
            AppleContainerRuntime(shell: FakeShell(), pool: pool, registryCache: cache)
        }
        XCTAssertNotNil(runtime(Pool(name: "d", image: "i", docker: true)).registryCache)
        XCTAssertNil(runtime(Pool(name: "o", image: "i", docker: true, dockerCache: false)).registryCache)
        XCTAssertNil(runtime(Pool(name: "n", image: "i", docker: false)).registryCache)
        XCTAssertNotNil(
            runtime(Pool(name: "x", image: "i", docker: true, platform: .amd64)).registryCache,
            "amd64 pools pull through the cache too")
    }

    // MARK: - The probe

    func testTheReachabilityCheckWaitsForACacheThatIsStillStarting() {
        XCTAssertEqual(
            AppleContainerRuntime.cacheReachabilityScript(address: "192.168.64.3"),
            "timeout 20 bash -c 'until : < /dev/tcp/192.168.64.3/5000; do sleep 1; done' 2>/dev/null")
        XCTAssertTrue(
            AppleContainerRuntime.cacheReachabilityScript(address: "10.0.0.2", seconds: 5).hasPrefix("timeout 5 "))
    }

    /// Runs the probe with `timeout` replaced by a bash function answering `status` (the host may have no `timeout`).
    private func runProbe(timeoutStatus status: Int) async throws -> ShellResult {
        let script = "timeout() { return \(status); }\n" + AppleContainerRuntime.cacheProbeScript(address: "10.9.9.9")
        return try await Shell().run(["/bin/bash", "-c", script], cwd: nil, timeout: 10)
    }

    func testTheProbePrintsTheMarkerOnceTheCacheAnswers() async throws {
        let result = try await runProbe(timeoutStatus: 0)
        XCTAssertTrue(result.succeeded, result.stderr)
        XCTAssertNotNil(AppleContainerRuntime.daemonJSON(fromProbeOutput: result.stdout), result.stdout)
    }

    func testTheProbeExitsWithItsOwnStatusWhenTheCacheNeverAnswers() async throws {
        let result = try await runProbe(timeoutStatus: 124)
        XCTAssertEqual(result.exitCode, AppleContainerRuntime.cacheUnreachableExitCode)
        XCTAssertTrue(result.stderr.contains("10.9.9.9:5000 did not answer within 20 s"), result.stderr)
        XCTAssertFalse(result.stdout.contains(AppleContainerRuntime.daemonJSONMarker))
    }

    func testTheTextAfterTheMarkerIsTheFile() {
        let marker = AppleContainerRuntime.daemonJSONMarker
        XCTAssertEqual(
            AppleContainerRuntime.daemonJSON(fromProbeOutput: "motd\nline\n\(marker)\n{\"a\": 1}\n"), "{\"a\": 1}\n")
        XCTAssertEqual(AppleContainerRuntime.daemonJSON(fromProbeOutput: "\(marker)\n"), "")
        XCTAssertEqual(AppleContainerRuntime.daemonJSON(fromProbeOutput: marker), "")
        XCTAssertNil(AppleContainerRuntime.daemonJSON(fromProbeOutput: "{\"a\": 1}"))
    }

    // MARK: - Through the engine

    private func makeEngine(
        _ shell: ContainerFakingShell, configure: (inout KinhinConfig) -> Void
    ) -> FleetEngine {
        var config = makeTestConfig()
        configure(&config)
        var dependencies = FleetEngine.Dependencies(
            tokenLoader: { _, _ in "test-token" }, spawnStagger: .milliseconds(10), exitWatchInterval: .milliseconds(20)
        )
        dependencies.registryCacheDirectory = dataDirectory.appendingPathComponent("registry-cache", isDirectory: true)
        return FleetEngine(
            config: config, github: FakeGitHub(), tart: FakeTart(), store: makeTestStore(), ssh: FakeSSH(),
            host: testHost, containerShell: shell, dependencies: dependencies)
    }

    private func registrations(_ shell: ContainerFakingShell) -> [String] {
        shell.argvSnapshot().filter { $0.contains("exec") }.compactMap(\.last).filter { $0.contains("./config.sh") }
    }

    private func cacheRuns(_ shell: ContainerFakingShell) -> [[String]] {
        shell.argvSnapshot().filter { $0.dropFirst().first == "run" && $0.contains(DockerRegistryCache.containerName) }
    }

    func testTheEngineStartsTheCacheAndPointsADockerRunnerAtIt() async throws {
        let shell = ContainerFakingShell()
        shell.answerExec(
            containing: AppleContainerRuntime.daemonJSONMarker,
            stdout: "\(AppleContainerRuntime.daemonJSONMarker)\n\(Self.githubImageFile)\n")
        let engine = makeEngine(shell) {
            $0.container = .init(image: "kinhin-ci-linux", cpus: 2, memoryGB: 4, minIdle: 1, docker: true)
        }

        try await engine.reconcileOnce()
        try await waitUntil(timeout: 10) { !self.registrations(shell).isEmpty }

        let run = try XCTUnwrap(cacheRuns(shell).first)
        XCTAssertEqual(
            run,
            DockerRegistryCache.runArguments(
                bin: try XCTUnwrap(run.first),
                dataDirectory: dataDirectory.appendingPathComponent("registry-cache", isDirectory: true)))
        let registration = try XCTUnwrap(registrations(shell).first)
        // The runner was created first (192.168.64.2), so the cache is 192.168.64.3.
        XCTAssertTrue(registration.contains("\"http://192.168.64.3:5000\""), registration)
        XCTAssertTrue(registration.contains("\"mtu\" : 1280"), registration)
        let records = await engine.status().records
        XCTAssertEqual(records.count, 1, "the cache is not a runner")
    }

    func testPoolsShareOneCacheAndAPoolWithItOffNeverAsks() async throws {
        let shell = ContainerFakingShell()
        shell.setImages(["kinhin-ci-linux:latest"])
        let engine = makeEngine(shell) {
            $0.maxRunners = 4
            $0.container = .init(
                image: "kinhin-ci-linux", cpus: 2, memoryGB: 4, docker: true,
                pools: [
                    .init(
                        name: "a", image: "kinhin-ci-linux", cpus: 1, memoryGB: 2, labels: ["a"], minIdle: 1,
                        docker: true),
                    .init(
                        name: "b", image: "kinhin-ci-linux", cpus: 1, memoryGB: 2, labels: ["b"], minIdle: 1,
                        docker: true),
                    .init(
                        name: "c", image: "kinhin-ci-linux", cpus: 1, memoryGB: 2, labels: ["c"], minIdle: 1,
                        docker: true, dockerCache: false),
                ])
        }

        try await engine.reconcileOnce()
        try await waitUntil(timeout: 10) { self.registrations(shell).count == 3 }

        XCTAssertEqual(cacheRuns(shell).count, 1, "one cache for every pool that uses it")
        let probes = shell.argvSnapshot().filter { $0.last?.contains(AppleContainerRuntime.daemonJSONMarker) == true }
        XCTAssertEqual(probes.count, 2, "pools a and b probe it, pool c does not")
        let records = await engine.status().records
        let cRecord = try XCTUnwrap(records.first { $0.pool == "c" })
        XCTAssertFalse(probes.contains { $0.contains(cRecord.id) }, "pool c's runner is never probed")
    }

    func testWithoutAPoolThatUsesItTheEngineNeverTouchesTheCache() async throws {
        for docker in [false, true] {
            let shell = ContainerFakingShell()
            let engine = makeEngine(shell) {
                $0.container = .init(
                    image: "kinhin-ci-linux", cpus: 2, memoryGB: 4, minIdle: 1, docker: docker, dockerCache: false)
            }
            try await engine.reconcileOnce()
            try await waitUntil(timeout: 10) { !self.registrations(shell).isEmpty }
            XCTAssertFalse(
                shell.argvSnapshot().contains { $0.contains(DockerRegistryCache.containerName) },
                "docker \(docker), cache off: no inspect, no run")
        }
    }
}
