import XCTest

@testable import KinhinKit
@testable import KinhinTestSupport

/// `linux/amd64` container pools (#75, step 3): the `x64` label in place of the fleet's `arm64`, a job routed by the
/// architecture it asks for, `container run --platform`, the GitHub demand filter that counts x64 jobs, and doctor.
final class ContainerPlatformRoutingTests: XCTestCase {
    private static func config(defaultRuntime: RuntimeID? = nil) -> KinhinConfig {
        var cfg = makeTestConfig()
        cfg.labels = ["self-hosted", "arm64", "macos"]
        cfg.container = .init(
            image: "kinhin-ci-linux", cpus: 2, memoryGB: 7,
            pools: [
                .init(name: "linux", image: "kinhin-ci-linux", cpus: 2, memoryGB: 7, labels: ["linux"]),
                .init(
                    name: "linux-x64", image: "kinhin-ci-linux-x64", cpus: 4, memoryGB: 8, labels: ["linux"],
                    platform: .amd64),
                .init(name: "big", image: "kinhin-ci-linux", cpus: 4, memoryGB: 12, labels: ["linux", "big"]),
            ])
        if let defaultRuntime { cfg.runtimes = .init(defaultRuntime: defaultRuntime) }
        return cfg
    }

    private static func job(_ labels: [String]) -> ForgeJob {
        ForgeJob(name: "ci / build", runnerName: nil, repository: "acme/widgets", labels: labels)
    }

    // MARK: - Labels

    func testAnAmd64PoolRegistersWithX64InPlaceOfArm64() throws {
        let table = RuntimeConfigModel(config: Self.config()).containerPools
        let x64 = try XCTUnwrap(table.entries.first { $0.name == "linux-x64" })
        XCTAssertEqual(
            x64.labels, ["self-hosted", "linux", "kinhin-container", "x64", "kinhin-container-linux-x64"])
        XCTAssertEqual(x64.platform, .amd64)
        let arm = try XCTUnwrap(table.entries.first { $0.name == "linux" })
        XCTAssertEqual(arm.labels, ["self-hosted", "arm64", "linux", "kinhin-container", "kinhin-container-linux"])
    }

    func testReplaceNotAddStillCarriesTheArchitecture() {
        let labels = RuntimePool.labelsFor(
            .appleContainer, fleetLabels: ["self-hosted", "arm64"], containerExtra: ["linux"],
            containerPlatform: .amd64, inheritingFleetLabels: false)
        XCTAssertEqual(labels, ["linux", "kinhin-container", "x64"])
    }

    func testASectionWithoutPoolsOnAmd64RegistersWithX64() {
        var cfg = makeTestConfig()
        cfg.labels = ["self-hosted", "arm64"]
        cfg.container = .init(image: "kinhin-ci-linux-x64", platform: .amd64)
        let labels = RuntimeConfigModel(config: cfg).pools[.appleContainer]?.labels
        XCTAssertEqual(labels, ["self-hosted", "kinhin-container", "x64"])
    }

    func testArm64PoolsKeepExactlyTheirLabels() {
        var cfg = makeTestConfig()
        cfg.labels = ["self-hosted", "arm64"]
        cfg.container = .init(image: "kinhin-ci-linux")
        XCTAssertEqual(
            RuntimeConfigModel(config: cfg).pools[.appleContainer]?.labels,
            ["self-hosted", "arm64", "kinhin-container"])
    }

    // MARK: - Which pool a job lands in

    func testAJobLandsInThePoolOfItsArchitecture() {
        let table = RuntimeConfigModel(config: Self.config()).containerPools
        XCTAssertEqual(table.pool(for: ["self-hosted", "x64", "linux"])?.name, "linux-x64")
        XCTAssertEqual(table.pool(for: ["self-hosted", "X64", "linux"])?.name, "linux-x64", "labels ignore case")
        XCTAssertEqual(table.pool(for: ["self-hosted", "arm64", "linux"])?.name, "linux")
        XCTAssertEqual(table.pool(for: ["self-hosted", "arm64", "linux", "big"])?.name, "big")
        XCTAssertEqual(table.pool(for: ["self-hosted", "linux"])?.name, "linux", "no architecture: the default pool")
    }

    func testAnX64JobWithoutAMatchingLabelGoesToAnX64Pool() {
        let table = RuntimeConfigModel(config: Self.config()).containerPools
        XCTAssertEqual(
            table.pool(for: ["self-hosted", "x64"])?.name, "linux-x64",
            "the default pool runs arm64, so the x64 pool with the fewest labels")
        XCTAssertEqual(
            table.pool(for: ["self-hosted", "x64", "big"])?.name, "linux-x64", "big runs arm64: never for an x64 job")
    }

    func testAPoolsMarkerStillWins() {
        let table = RuntimeConfigModel(config: Self.config()).containerPools
        XCTAssertEqual(table.pool(for: ["self-hosted", "arm64", "kinhin-container-linux-x64"])?.name, "linux-x64")
    }

    func testAnX64JobGoesToAppleContainerWhenTheDefaultRuntimeIsTart() {
        let model = RuntimeConfigModel(config: Self.config(defaultRuntime: .tart))
        XCTAssertEqual(model.runtime(for: Self.job(["self-hosted", "x64", "linux"])), .appleContainer)
        XCTAssertEqual(model.runtime(for: Self.job(["self-hosted", "arm64"])), .tart, "arm64 jobs keep the default")
    }

    func testAnX64JobStaysOnTartWithoutAnX64Pool() {
        var cfg = Self.config(defaultRuntime: .tart)
        cfg.container?.pools.removeAll { $0.platform == .amd64 }
        XCTAssertEqual(RuntimeConfigModel(config: cfg).runtime(for: Self.job(["self-hosted", "x64"])), .tart)
    }

    // MARK: - The runtime

    func testAnAmd64PoolStartsItsContainersWithThePlatform() async throws {
        let bin = "/usr/local/bin/container"
        let shell = FakeShell()
        let pool = try XCTUnwrap(Self.config().container?.pools.first { $0.name == "linux-x64" })
        XCTAssertEqual(AppleContainerRuntime(shell: shell, pool: pool).platform, .amd64, "the pool hands it over")
        let runtime = AppleContainerRuntime(
            shell: shell, image: pool.image, cpus: pool.cpus, memoryGB: pool.memoryGB, platform: pool.platform,
            binPath: bin)
        try await runtime.provision(
            id: "kinhin-abc",
            route: RepoRoute(repo: "acme/widgets", image: "tahoe-base", ephemeral: true, bootTimeout: 30))
        let run = try XCTUnwrap(shell.calls.last)
        XCTAssertEqual(
            Array(run.prefix(12)),
            [
                bin, "run", "--detach", "--name", "kinhin-abc", "--cpus", "4", "--memory", "8192M", "--platform",
                "linux/amd64", "--rm",
            ])
    }

    func testArm64RunFlagsAreUnchanged() {
        XCTAssertEqual(AppleContainerRuntime.platformRunFlags(.arm64), [])
        XCTAssertEqual(AppleContainerRuntime.platformRunFlags(.amd64), ["--platform", "linux/amd64"])
    }

    func testTheBenchmarkRunsTheDefaultPoolsPlatformUnlessToldOtherwise() throws {
        var cfg = Self.config()
        cfg.container?.pools = [.init(name: "x64", image: "kinhin-ci-linux-x64", platform: .amd64)]
        let env = BenchmarkEnvironment(config: cfg, tart: FakeTart(), ssh: FakeSSH(), shell: FakeShell())
        let pooled = try XCTUnwrap(env.makeRuntime(.appleContainer, nil) as? AppleContainerRuntime)
        XCTAssertEqual(pooled.platform, .amd64, "the fleet runs it as amd64, so the benchmark must too")
        let overridden = try XCTUnwrap(env.makeRuntime(.appleContainer, .arm64) as? AppleContainerRuntime)
        XCTAssertEqual(overridden.platform, .arm64, "a benchmark's explicit platform wins, as for Docker")
    }

    // MARK: - GitHub demand

    func testX64JobsCountAsDemandOnceAPoolServesThem() async throws {
        let served = Router.Snapshot.make(config: Self.config(), host: testHost).servedLabels
        XCTAssertEqual(
            GitHubForge.demandLabelSets(fleetLabels: ["self-hosted", "arm64"], servedLabels: served),
            [["self-hosted", "arm64"], ["self-hosted", "x64"]])
        XCTAssertEqual(
            GitHubForge.demandLabelSets(
                fleetLabels: ["self-hosted", "arm64"], servedLabels: ["self-hosted", "arm64"]),
            [["self-hosted", "arm64"]], "without an x64 pool, exactly the fleet labels")

        let github = FakeGitHub()
        github.queueDepth = 1
        let relabeled = GitHubForge(
            credentials: .github(token: "t", scope: "acme", instance: nil, allowInsecureHTTP: false),
            labels: ["self-hosted", "arm64"], client: github
        ).relabeled(fleetLabels: ["self-hosted", "arm64"], servedLabels: served)
        let counted = try XCTUnwrap(relabeled as? GitHubForge)
        XCTAssertEqual(counted.demandLabelSets.count, 2, "a reload hands the served labels over")
        for (labels, counts) in [
            (["self-hosted", "X64", "linux"], true),
            (["self-hosted", "arm64", "linux"], true),
            (["self-hosted", "linux"], false),
            (["blacksmith-4vcpu"], false),
        ] {
            github.queueExtraLabels = labels
            let jobs = try await counted.queuedJobs()
            XCTAssertEqual(jobs.count, counts ? 1 : 0, "\(labels)")
        }
    }

    func testRunningJobsOfOtherRunnersAreLeftOut() async throws {
        let github = FakeGitHub()
        github.running = [
            RunningJob(name: "ours", runnerName: "kinhin-1", repository: nil, labels: ["self-hosted", "x64"]),
            RunningJob(name: "theirs", runnerName: "bs-1", repository: nil, labels: ["blacksmith-4vcpu"]),
        ]
        let forge = GitHubForge(
            credentials: .github(token: "t", scope: "acme", instance: nil, allowInsecureHTTP: false),
            labels: ["self-hosted", "arm64"], client: github, servedLabels: ["x64"])
        let running = try await forge.runningJobs()
        XCTAssertEqual(running.map(\.name), ["ours"])
    }

    // MARK: - Doctor

    func testDoctorShowsAnAmd64Pool() {
        let status = DoctorReport.ContainerPoolStatus(
            name: "linux-x64", image: "kinhin-ci-linux-x64", imageFound: true, cpus: 4, memoryGB: 8, max: nil,
            docker: false, fits: true, budgetCPU: 12, budgetMemoryGB: 44, platform: "linux/amd64")
        XCTAssertEqual(
            DoctorReport.containerPoolLine(status, runtimeReady: true),
            "linux-x64 (4 CPU, 8 GB, linux/amd64 (Rosetta)): kinhin-ci-linux-x64 ✓")
    }
}
