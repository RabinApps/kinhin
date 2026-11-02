import XCTest

@testable import KinhinKit
@testable import KinhinTestSupport

/// Named container pools through a real reconcile pass (#75, step 2): a job lands in its pool's container (the
/// pool's image, shape and flags, registered with the pool's labels), a pool's floor starts its own idle runner, and
/// an instance remembers its pool.
final class ContainerPoolsEngineTests: XCTestCase {
    private func makeEngine(
        shell: ContainerFakingShell, github: FakeGitHub, store: FleetStore = makeTestStore(),
        images: [String] = ["kinhin-ci-linux", "kinhin-ci-big"], configure: (inout KinhinConfig) -> Void = { _ in }
    ) -> FleetEngine {
        var config = makeTestConfig()
        config.container = .init(
            image: "kinhin-ci-linux", cpus: 2, memoryGB: 4,
            pools: [
                .init(
                    name: "big", image: "kinhin-ci-big", cpus: 3, memoryGB: 6, labels: ["linux", "big"],
                    flags: ["--shm-size", "2g"], max: 2),
                .init(name: "linux", image: "kinhin-ci-linux", cpus: 2, memoryGB: 4, labels: ["linux"], docker: true),
            ])
        configure(&config)
        // Both pools' images are built unless a test says otherwise (an unbuilt pool's runners never start).
        shell.setImages(images)
        return FleetEngine(
            config: config, github: github, tart: FakeTart(), store: store, ssh: FakeSSH(), host: testHost,
            containerShell: shell,
            dependencies: .init(tokenLoader: { _, _ in "test-token" }, exitWatchInterval: .milliseconds(20)))
    }

    private func runArgv(_ shell: ContainerFakingShell) -> [String]? {
        shell.argvSnapshot().first { $0.dropFirst().first == "run" }
    }

    func testAJobLandsInItsPoolsContainer() async throws {
        let shell = ContainerFakingShell()
        let github = FakeGitHub()
        github.queueDepth = 1
        github.queueExtraLabels = ["linux", "big"]
        let engine = makeEngine(shell: shell, github: github)

        try await engine.reconcileOnce()
        try await waitUntil(timeout: 10) {
            shell.argvSnapshot().contains { $0.contains("exec") && $0.contains("<stdin>") }
        }

        let run = try XCTUnwrap(runArgv(shell))
        let cpus = try XCTUnwrap(run.firstIndex(of: "--cpus"))
        XCTAssertEqual(Array(run[cpus...].prefix(4)), ["--cpus", "3", "--memory", "6144M"], "\(run)")
        XCTAssertEqual(Array(run[(cpus + 4)...].prefix(4)), ["--shm-size", "2g", "--rm", "kinhin-ci-big"], "\(run)")
        XCTAssertFalse(run.contains("--cap-add"), "docker is linux's, not big's")
        let records = await engine.status().records
        let record = try XCTUnwrap(records.first)
        XCTAssertEqual(record.pool, "big")
        XCTAssertEqual(record.runtimeID, .appleContainer)
        let exec = try XCTUnwrap(shell.argvSnapshot().first { $0.contains("exec") && $0.contains("<stdin>") })
        XCTAssertTrue(
            exec.last?.contains("kinhin-container-big") == true, "the runner registers with its pool's marker")
    }

    func testAJobNoPoolClaimsRunsInTheDefaultPool() async throws {
        let shell = ContainerFakingShell()
        let github = FakeGitHub()
        github.queueDepth = 1
        let engine = makeEngine(shell: shell, github: github)

        try await engine.reconcileOnce()
        try await waitUntil(timeout: 10) { runArgv(shell) != nil }

        let run = try XCTUnwrap(runArgv(shell))
        XCTAssertTrue(run.contains("kinhin-ci-linux"), "\(run)")
        XCTAssertTrue(run.contains("--cap-add"), "the default pool, linux, runs Docker")
        let records = await engine.status().records
        XCTAssertEqual(records.first?.pool, "linux")
    }

    func testAPoolsFloorStartsItsOwnIdleRunner() async throws {
        let shell = ContainerFakingShell()
        let engine = makeEngine(shell: shell, github: FakeGitHub()) { $0.container?.pools[0].minIdle = 1 }

        try await engine.reconcileOnce()
        try await waitUntil(timeout: 10) { runArgv(shell) != nil }

        XCTAssertTrue(runArgv(shell)?.contains("kinhin-ci-big") == true)
        let records = await engine.status().records
        XCTAssertEqual(records.map(\.pool), ["big"])
    }

    func testEachRecordRunsOnItsPoolsRuntime() throws {
        let engine = makeEngine(shell: ContainerFakingShell(), github: FakeGitHub())
        var record = VMRecord(id: "kinhin-1700000000-0000abcd", phase: .ready)
        record.runtimeID = .appleContainer
        record.pool = "big"
        let big = try XCTUnwrap(engine.runtime(for: record) as? AppleContainerRuntime)
        XCTAssertEqual(big.image, "kinhin-ci-big")
        XCTAssertEqual(big.cpus, 3)
        XCTAssertEqual(big.flags, ["--shm-size", "2g"])
        record.pool = nil
        let fallback = try XCTUnwrap(engine.runtime(for: record) as? AppleContainerRuntime)
        XCTAssertEqual(fallback.image, "kinhin-ci-linux", "no pool: the default pool's runtime")
        XCTAssertTrue(fallback.docker)
    }

    func testARecordKeepsItsPoolAcrossARestart() {
        let store = makeTestStore()
        var record = VMRecord(id: "kinhin-1700000000-0000abcd", phase: .ready)
        record.runtimeID = .appleContainer
        record.pool = "big"
        record.platform = "github"
        store.upsert(record)
        let reloaded = FleetStore(directory: store.directory)
        XCTAssertEqual(reloaded.all.first?.pool, "big", "the pool is persisted with the record")
    }

    // MARK: - A pool whose image is not built

    func testAnUnbuiltPoolsJobWaitsInsteadOfStartingAnotherPool() async throws {
        let shell = ContainerFakingShell()
        let github = FakeGitHub()
        github.queueDepth = 1
        github.queueExtraLabels = ["linux", "big"]
        let engine = makeEngine(shell: shell, github: github, images: ["kinhin-ci-linux:latest"])

        try await engine.reconcileOnce()
        try await engine.reconcileOnce()

        XCTAssertNil(runArgv(shell), "nothing starts: big's image is missing and linux cannot take big's job")
        let records = await engine.status().records
        XCTAssertTrue(records.isEmpty)
        XCTAssertTrue(engine.spawnBackoff.withLock { $0.blocked(now: Date()) }.isEmpty, "no failed start, no backoff")
        let listings = shell.argvSnapshot().filter { $0.dropFirst().first == "image" }
        XCTAssertEqual(listings.count, 1, "the image listing is cached across passes")
    }

    func testAnUnbuiltPoolsFloorIsSkippedAndTheOtherPoolsRun() async throws {
        let shell = ContainerFakingShell()
        let github = FakeGitHub()
        github.queueDepth = 1
        github.queueExtraLabels = ["linux"]
        let engine = makeEngine(shell: shell, github: github, images: ["kinhin-ci-linux"]) {
            $0.container?.pools[0].minIdle = 1
        }

        try await engine.reconcileOnce()
        try await waitUntil(timeout: 10) { runArgv(shell) != nil }

        let runs = shell.argvSnapshot().filter { $0.dropFirst().first == "run" }
        XCTAssertEqual(runs.count, 1, "linux's job starts; big's floor is left out")
        XCTAssertTrue(runs.first?.contains("kinhin-ci-linux") == true)
        let records = await engine.status().records
        XCTAssertEqual(records.map(\.pool), ["linux"])
    }

    func testAFailedImageListingSkipsNoPool() async throws {
        let shell = ContainerFakingShell()
        let engine = makeEngine(shell: shell, github: FakeGitHub()) { $0.container?.pools[0].minIdle = 1 }
        shell.failImageList()

        let unbuilt = await engine.unpreparedContainerPools()
        XCTAssertEqual(unbuilt, [], "an unknown listing is not proof that every pool is unbuilt")
    }

    func testAPoolIsUnbuiltWhenNoLocalTagMatchesItsImage() async {
        let shell = ContainerFakingShell()
        let engine = makeEngine(shell: shell, github: FakeGitHub(), images: ["kinhin-ci-linux:latest", "other"])
        let unbuilt = await engine.unpreparedContainerPools()
        XCTAssertEqual(unbuilt, ["big"])
    }

    func testASectionWithoutPoolsStartsExactlyAsBefore() async throws {
        let shell = ContainerFakingShell()
        let github = FakeGitHub()
        github.queueDepth = 1
        let engine = makeEngine(shell: shell, github: github) { $0.container?.pools = [] }

        try await engine.reconcileOnce()
        try await waitUntil(timeout: 10) { runArgv(shell) != nil }

        let run = try XCTUnwrap(runArgv(shell))
        let cpus = try XCTUnwrap(run.firstIndex(of: "--cpus"))
        XCTAssertEqual(Array(run[cpus...].prefix(6)), ["--cpus", "2", "--memory", "4096M", "--rm", "kinhin-ci-linux"])
        XCTAssertFalse(
            shell.argvSnapshot().contains { $0.dropFirst().first == "image" }, "no image listing without pools")
        let records = await engine.status().records
        XCTAssertNil(records.first?.pool)
    }
}
