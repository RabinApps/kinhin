import XCTest

@testable import KinhinKit
@testable import KinhinTestSupport

/// `docker: { build_cache: true }` (#107): each Docker runner gets a volume of its own at /var/lib/docker, never one
/// another container holds, created the first time; the runner's container records it as a label; the registration
/// clears the last job's leftovers; teardown stops dockerd first; and with the option off nothing changes.
final class DockerBuildCacheVolumesTests: XCTestCase {
    private let bin = "/usr/local/bin/container"
    private let tail = ["--rm", "kinhin-ci-linux", "/bin/bash", "-lc", "while true; do sleep 3600; done"]

    /// `container list --all --format json` with containers holding `volumes`.
    private static func listed(_ volumes: [String]) -> ShellResult {
        let rows = volumes.enumerated().map { index, volume in
            #"{"configuration":{"id":"kinhin-\#(index)","labels":{"kinhin.docker-build-cache":"\#(volume)"}},"status":"running"}"#
        }
        return ShellResult(exitCode: 0, stdout: "[\(rows.joined(separator: ","))]", stderr: "")
    }

    private static let ok = ShellResult(exitCode: 0, stdout: "", stderr: "")
    private static let noVolume = ShellResult(exitCode: 1, stdout: "", stderr: "Error: volume not found")

    // MARK: - Leasing

    func testTheFirstRunnerGetsSlotZeroCreatedOnce() async {
        let shell = FakeShell()
        shell.responses = [Self.listed([]), Self.noVolume, Self.ok]
        let volumes = DockerBuildCacheVolumes(shell: shell, binPath: bin)
        let volume = await volumes.lease(for: "kinhin-a", pool: "arm64")
        XCTAssertEqual(volume, "docker-cache-kinhin-arm64-0")
        XCTAssertEqual(shell.calls[0], [bin, "list", "--all", "--format", "json"])
        XCTAssertEqual(shell.calls[1], [bin, "volume", "inspect", "docker-cache-kinhin-arm64-0"])
        XCTAssertEqual(
            shell.calls[2],
            [
                bin, "volume", "create", "-s", "64G", "--label", "kinhin.docker-build-cache=arm64",
                "docker-cache-kinhin-arm64-0",
            ])
    }

    func testAnExistingVolumeIsReusedWithoutCreatingIt() async {
        let shell = FakeShell()
        shell.responses = [Self.listed([]), Self.ok]
        let volume = await DockerBuildCacheVolumes(shell: shell, binPath: bin).lease(for: "kinhin-a", pool: "")
        XCTAssertEqual(volume, "docker-cache-kinhin-default-0", "the unnamed pool's volumes say so")
        XCTAssertFalse(shell.calls.contains { $0.contains("create") })
    }

    func testAVolumeAnotherContainerHoldsIsSkipped() async {
        // Two dockerds on one data root corrupt it: a held volume is never handed out again.
        let shell = FakeShell()
        shell.responses = [
            Self.listed(["docker-cache-kinhin-arm64-0", "docker-cache-kinhin-arm64-2", "docker-cache-kinhin-x64-1"]),
            Self.ok,
        ]
        let volume = await DockerBuildCacheVolumes(shell: shell, binPath: bin).lease(for: "kinhin-b", pool: "arm64")
        XCTAssertEqual(volume, "docker-cache-kinhin-arm64-1")
    }

    func testALeaseWhoseContainerIsNotListedYetIsNotHandedOutTwice() async {
        let shell = FakeShell()
        shell.defaultResult = Self.ok
        shell.responses = [Self.listed([]), Self.ok, Self.listed([]), Self.ok]
        let volumes = DockerBuildCacheVolumes(shell: shell, binPath: bin)
        let first = await volumes.lease(for: "kinhin-a", pool: "p")
        let second = await volumes.lease(for: "kinhin-b", pool: "p")
        XCTAssertEqual(first, "docker-cache-kinhin-p-0")
        XCTAssertEqual(second, "docker-cache-kinhin-p-1")

        // Once a's container exists (or failed), the listing is the truth again.
        await volumes.provisioned("kinhin-a")
        shell.responses = [Self.listed([]), Self.ok]
        let third = await volumes.lease(for: "kinhin-c", pool: "p")
        XCTAssertEqual(third, "docker-cache-kinhin-p-0")
    }

    func testNoListingMeansNoCacheRatherThanAGuess() async {
        let shell = FakeShell()
        shell.responses = [ShellResult(exitCode: 1, stdout: "", stderr: "XPC connection error")]
        let volume = await DockerBuildCacheVolumes(shell: shell, binPath: bin).lease(for: "kinhin-a", pool: "p")
        XCTAssertNil(volume)
        XCTAssertEqual(shell.calls.count, 1, "nothing is created")
    }

    func testAVolumeThatCannotBeCreatedMeansNoCache() async {
        let shell = FakeShell()
        shell.responses = [
            Self.listed([]), Self.noVolume, ShellResult(exitCode: 1, stdout: "", stderr: "Error: no space left"),
        ]
        let volume = await DockerBuildCacheVolumes(shell: shell, binPath: bin).lease(for: "kinhin-a", pool: "p")
        XCTAssertNil(volume)
    }

    func testHeldVolumesAreReadFromTheListing() {
        XCTAssertEqual(
            DockerBuildCacheVolumes.parseHeldVolumes(Self.listed(["v1", "v2"]).stdout), ["v1", "v2"])
        XCTAssertEqual(
            DockerBuildCacheVolumes.parseHeldVolumes(#"[{"configuration":{"id":"web","labels":{}}}]"#), [])
        XCTAssertEqual(DockerBuildCacheVolumes.parseHeldVolumes(""), [])
        XCTAssertEqual(DockerBuildCacheVolumes.parseHeldVolumes("not json"), [])
    }

    // MARK: - The runtime

    private func pool(buildCache: Bool, docker: Bool = true) -> KinhinConfig.ContainerConfig.Pool {
        .init(
            name: "arm64", image: "kinhin-ci-linux", cpus: 3, memoryGB: 6, docker: docker,
            dockerBuildCache: buildCache)
    }

    func testARunnerStartsWithItsVolumeAtTheDockerDataRoot() async throws {
        let shell = FakeShell()
        shell.responses = [Self.listed([]), Self.ok, Self.ok, Self.ok]
        let runtime = AppleContainerRuntime(
            shell: shell, pool: pool(buildCache: true), buildCacheVolumes: DockerBuildCacheVolumes(shell: shell))
        try await runtime.provision(id: "kinhin-abc", route: makeRoute())
        let run = try XCTUnwrap(shell.calls.last)
        XCTAssertEqual(
            Array(run.suffix(tail.count + 4).prefix(4)),
            [
                "--volume", "docker-cache-kinhin-arm64-0:/var/lib/docker",
                "--label", "kinhin.docker-build-cache=docker-cache-kinhin-arm64-0",
            ])
        XCTAssertEqual(Array(run.suffix(tail.count)), tail)
    }

    func testWithTheOptionOffTheEngineVolumesAreIgnored() async throws {
        let shell = FakeShell()
        let runtime = AppleContainerRuntime(
            shell: shell, pool: pool(buildCache: false), buildCacheVolumes: DockerBuildCacheVolumes(shell: shell))
        XCTAssertNil(runtime.buildCacheVolumes)
        try await runtime.provision(id: "kinhin-abc", route: makeRoute())
        XCTAssertFalse(shell.calls.contains { $0.contains("volume") || $0.contains("--volume") })
        let withoutDocker = AppleContainerRuntime(
            shell: shell, pool: pool(buildCache: true, docker: false),
            buildCacheVolumes: DockerBuildCacheVolumes(shell: shell))
        XCTAssertNil(withoutDocker.buildCacheVolumes, "build_cache means nothing without Docker")
    }

    func testARunnerWithoutAVolumeStartsAsBefore() async throws {
        let shell = FakeShell()
        shell.responses = [ShellResult(exitCode: 1, stdout: "", stderr: "XPC connection error")]
        let runtime = AppleContainerRuntime(
            shell: shell, pool: pool(buildCache: true), buildCacheVolumes: DockerBuildCacheVolumes(shell: shell))
        try await runtime.provision(id: "kinhin-abc", route: makeRoute())
        let run = try XCTUnwrap(shell.calls.last)
        XCTAssertFalse(run.contains("--volume"), "\(run)")
        XCTAssertTrue(run.contains("--cap-add"))
    }

    private func registrationScript(buildCache: Bool) async throws -> String {
        let runtime = AppleContainerRuntime(
            shell: FakeShell(), pool: pool(buildCache: buildCache), buildCacheVolumes: DockerBuildCacheVolumes())
        let github = GitHubForge(
            credentials: .github(token: "t", scope: "acme/widgets"), labels: ["kinhin"], client: FakeGitHub())
        return try await runtime.registrationScript(
            forge: github, token: "RT", name: "kinhin-1", runnerCount: 1, route: makeRoute(), labels: nil)
    }

    func testTheRegistrationClearsTheLastJobsLeftoversAfterDockerdStarts() async throws {
        let script = try await registrationScript(buildCache: true)
        let daemon = try XCTUnwrap(script.range(of: "dockerd started"))
        let leftovers = try XCTUnwrap(script.range(of: "docker rm -f $leftover_containers"))
        let register = try XCTUnwrap(script.range(of: "./config.sh --url"))
        XCTAssertLessThan(daemon.lowerBound, leftovers.lowerBound, "dockerd must answer first")
        XCTAssertLessThan(leftovers.lowerBound, register.lowerBound, "cleared before the runner can take a job")
        XCTAssertTrue(script.contains("grep -v '^buildx_buildkit_'"), "the amd64 builder's cache stays")
        XCTAssertTrue(script.contains("docker system prune -af"))
        let syntax = try await Shell().run(["/bin/bash", "-n", "-c", script], cwd: nil, timeout: 10)
        XCTAssertTrue(syntax.succeeded, "composed registration script: \(syntax.stderr)")

        let before = try await registrationScript(buildCache: false)
        XCTAssertFalse(before.contains("leftover_containers"), "unchanged with the option off")
    }

    func testTeardownStopsDockerdBeforeDeletingTheRunner() async throws {
        let shell = FakeShell()
        let runtime = AppleContainerRuntime(
            shell: shell, pool: pool(buildCache: true), buildCacheVolumes: DockerBuildCacheVolumes(shell: shell))
        try await runtime.teardown(id: "kinhin-abc")
        XCTAssertEqual(shell.calls.map { Array($0.dropFirst().prefix(1)) }, [["exec"], ["delete"]])

        let plain = FakeShell()
        try await AppleContainerRuntime(shell: plain, pool: pool(buildCache: false)).teardown(id: "kinhin-abc")
        XCTAssertEqual(plain.calls.map { Array($0.dropFirst().prefix(1)) }, [["delete"]])
    }

    func testTheStopScriptStopsContainersThenDockerdThenSyncs() {
        let script = AppleContainerRuntime.dockerStopScript(seconds: 20)
        let order = ["docker stop", "kill -TERM", "sync"].map { script.range(of: $0)?.lowerBound }
        XCTAssertFalse(order.contains(nil), script)
        XCTAssertEqual(order.compactMap { $0 }, order.compactMap { $0 }.sorted())
    }

    // MARK: - Helpers

    private func makeRoute() -> RepoRoute {
        RepoRoute(repo: "acme/widgets", image: "tahoe-base", ephemeral: true, bootTimeout: 30)
    }
}
