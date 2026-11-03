import XCTest

@testable import KinhinKit
@testable import KinhinTestSupport

/// `kinhin doctor` and its JSON with the Docker Hub cache: a cache row (running or not, address, data size) when some
/// pool uses it, each pool's cache setting, and reports from before the cache still decoding.
final class RegistryCacheDoctorTests: XCTestCase {
    private let host = HostResources(logicalCores: 10, memoryGB: 32, freeDiskGB: 200, arm64: true)
    private let running = DoctorReport.RegistryCacheStatus(
        running: true, address: "192.168.64.3:5000", dataBytes: 2_500_000_000,
        dataDirectory: "/Users/me/Library/Application Support/Kinhin/registry-cache", problem: nil)

    private func config(docker: Bool = true, cache: Bool = true, pools: [KinhinConfig.ContainerConfig.Pool] = [])
        -> KinhinConfig
    {
        // A real account scope: the doctor reads a placeholder (template) config as not set up yet.
        var cfg = makeTestConfig()
        cfg.container = .init(image: "kinhin-ci-linux", docker: docker, dockerCache: cache, pools: pools)
        return cfg
    }

    private func section(_ cfg: KinhinConfig) -> DoctorReport.ContainerSection? {
        DoctorReportBuilder.containerSection(
            config: cfg, health: .ready, images: .init(names: ["kinhin-ci-linux:latest"]), host: host,
            registryCache: running)
    }

    // MARK: - The section

    func testTheSectionCarriesTheCacheWhenAPoolUsesIt() throws {
        XCTAssertEqual(try XCTUnwrap(section(config())).registryCache, running)
        let pools = config(
            docker: false,
            pools: [
                .init(name: "dind", image: "kinhin-ci-linux", labels: ["dind"], docker: true),
                .init(name: "plain", image: "kinhin-ci-linux", labels: ["plain"]),
            ])
        XCTAssertEqual(try XCTUnwrap(section(pools)).registryCache, running, "one pool using it is enough")
    }

    func testNoCacheRowWithoutDockerOrWithTheCacheOff() throws {
        XCTAssertNil(try XCTUnwrap(section(config(docker: false))).registryCache)
        XCTAssertNil(try XCTUnwrap(section(config(cache: false))).registryCache)
    }

    func testEachPoolSaysWhetherItUsesTheCache() throws {
        let pools = try XCTUnwrap(
            section(
                config(pools: [
                    .init(name: "a", image: "kinhin-ci-linux", labels: ["a"], docker: true),
                    .init(name: "b", image: "kinhin-ci-linux", labels: ["b"], docker: true, dockerCache: false),
                    .init(name: "c", image: "kinhin-ci-linux", labels: ["c"], docker: false),
                ]))?.pools)
        XCTAssertEqual(pools.map(\.dockerCache), [true, false, false])
        XCTAssertTrue(DoctorReport.containerPoolLine(pools[0], runtimeReady: true).contains(", docker)"))
        XCTAssertTrue(
            DoctorReport.containerPoolLine(pools[1], runtimeReady: true).contains(", docker (no cache))"),
            DoctorReport.containerPoolLine(pools[1], runtimeReady: true))
    }

    // MARK: - Text

    func testTheCacheLineSaysWhereItRunsAndWhatItHolds() {
        let line = DoctorReport.registryCacheLine(running)
        XCTAssertTrue(line.hasPrefix("running at 192.168.64.3:5000 ✓"), line)
        XCTAssertTrue(
            line.contains("2.5 GB cached in /Users/me/Library/Application Support/Kinhin/registry-cache"), line)
    }

    func testANotRunningCacheIsNoFailure() {
        let idle = DoctorReport.RegistryCacheStatus(
            running: false, address: nil, dataBytes: nil, dataDirectory: "/x", problem: nil)
        let line = DoctorReport.registryCacheLine(idle)
        XCTAssertTrue(line.hasPrefix("not running (the first Docker runner starts it)"), line)
        XCTAssertTrue(line.contains("nothing cached in /x"), line)
        XCTAssertFalse(line.contains("✗"), line)

        let unreadable = DoctorReport.RegistryCacheStatus(
            running: false, address: nil, dataBytes: 0, dataDirectory: "/x", problem: "XPC connection error")
        XCTAssertTrue(DoctorReport.registryCacheLine(unreadable).contains(" — XPC connection error"))
    }

    // MARK: - JSON

    func testTheJSONCarriesTheCacheFields() throws {
        let data = try JSONEncoder().encode(try XCTUnwrap(section(config())))
        let object = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let cache = try XCTUnwrap(object["registryCache"] as? [String: Any])
        XCTAssertEqual(cache["running"] as? Bool, true)
        XCTAssertEqual(cache["address"] as? String, "192.168.64.3:5000")
        XCTAssertEqual(cache["dataBytes"] as? Int, 2_500_000_000)
        XCTAssertNotNil(cache["dataDirectory"])
    }

    func testAReportFromBeforeTheCacheStillDecodes() throws {
        let section = #"{"state":"ready","ok":true,"image":"kinhin-ci-linux","imageFound":true}"#
        let decoded = try JSONDecoder().decode(DoctorReport.ContainerSection.self, from: Data(section.utf8))
        XCTAssertNil(decoded.registryCache)
        let pool = """
            {"name":"a","image":"i","imageFound":true,"cpus":2,"memoryGB":4,"docker":true,"fits":true,
             "budgetCPU":8,"budgetMemoryGB":28}
            """
        let decodedPool = try JSONDecoder().decode(DoctorReport.ContainerPoolStatus.self, from: Data(pool.utf8))
        XCTAssertNil(decodedPool.dockerCache)
    }

    // MARK: - The builder

    private func report(
        _ cfg: KinhinConfig, registryCache: DoctorReport.RegistryCacheStatus?
    ) async -> DoctorReport {
        await DoctorReportBuilder(
            host: host, clt: .ok(version: "27.0"), tartHealth: .healthy, tartList: [], config: .loaded(cfg),
            authLoad: { _ in "token" }, accountLoad: { _, _ in "token" }, containerHealth: .ready,
            containerImages: .init(names: ["kinhin-ci-linux:latest"]), dockerInstalled: false,
            softnetInstalled: false, fleet: [], projectRecords: [], registryCache: registryCache
        ).build()
    }

    func testTheBuilderShowsTheCacheItWasGiven() async throws {
        let built = await report(config(), registryCache: running)
        XCTAssertEqual(built.container?.registryCache, running)
        XCTAssertTrue(built.plainText.contains("cont cache: running at 192.168.64.3:5000 ✓"), built.plainText)
    }

    func testWithInjectedHealthTheBuilderNeverAsksTheRealCLI() async throws {
        let built = await report(config(), registryCache: nil)
        XCTAssertNil(built.container?.registryCache, "no fixture and no live probe in a test")
        XCTAssertFalse(built.plainText.contains("cont cache"))
    }

    func testTheLiveProbeReadsTheCacheWithoutStartingIt() async {
        let shell = FakeShell()
        shell.responses = [
            ShellResult(
                exitCode: 0,
                stdout: #"[{"status":{"state":"running","networks":[{"ipv4Address":"192.168.64.3/24"}]}}]"#,
                stderr: "")
        ]
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("doctor-cache-\(UUID().uuidString)")
        let cache = DockerRegistryCache(shell: shell, binPath: "/usr/local/bin/container", dataDirectory: dir)
        let status = await DoctorReportBuilder.registryCacheStatus(runtimeReady: true, cache: cache)
        XCTAssertEqual(
            status,
            .init(running: true, address: "192.168.64.3:5000", dataBytes: nil, dataDirectory: dir.path, problem: nil))
        XCTAssertEqual(shell.calls, [["/usr/local/bin/container", "inspect", "registry-cache-kinhin"]])
    }

    func testWithTheRuntimeDownTheProbeDoesNotCallTheCLI() async {
        let shell = FakeShell()
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("doctor-cache-\(UUID().uuidString)")
        let cache = DockerRegistryCache(shell: shell, dataDirectory: dir)
        let status = await DoctorReportBuilder.registryCacheStatus(runtimeReady: false, cache: cache)
        XCTAssertFalse(status.running)
        XCTAssertEqual(status.problem, "the container runtime is not ready")
        XCTAssertEqual(shell.calls, [])
    }
}
