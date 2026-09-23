import XCTest
@testable import kinhin
@testable import KinhinKit

/// The full route-editing path, end to end: the CLI subcommand writes a
/// route through the validated editor onto a scratch config, a live engine
/// reloads from that same file (the daemon's reload_config flow), and the
/// engine's demand bucketing sends a matching job to the routed pool — not
/// the default one.
///
/// The KinhinKit test bundle keeps its own fakes, so this suite carries
/// minimal local doubles for the engine's collaborators. The engine never
/// reconciles here (no timers), so the doubles only need to exist.
final class RouteToEngineReloadTests: XCTestCase {
    private let host = HostResources(logicalCores: 12, memoryGB: 32, freeDiskGB: 200, arm64: true)

    override func setUp() async throws {
        try await super.setUp()
        scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("kinhin-route-e2e-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: scratch)
        try await super.tearDown()
    }

    private var scratch: URL!

    private var configURL: URL { scratch.appendingPathComponent("config.yaml") }

    /// The macOS-side config without routing or budget; `mixedYAML` composes
    /// the Linux side on top (container routes are rejected without a
    /// container section).
    private let baseYAML = """
    repo: "acme/widgets"
    labels: ["self-hosted", "macos", "arm64"]
    max_runners: 4
    poll_interval: 30
    vm:
      cpu: 4
      memory_gb: 8
    image: "tahoe-base"
    reserve:
      cpu: 2
      memory_gb: 4
    """

    private let containerYAML = """
    container:
      image: "kinhin-ci-linux"
      cpus: 2
      memory_gb: 4
    """

    /// A true mixed fleet: an even budget split so the reload materializes
    /// both pools' caps (usable 10 cpu / 28 GB → container 5/14, tart 5/14).
    private var mixedYAML: String {
        baseYAML + "\n" + containerYAML + "\nruntimes:\n  default: tart\n  budget: {tart: 0.5, appleContainer: 0.5}\n"
    }

    // MARK: - Local doubles (Kit fakes live in the other test bundle)

    private final class StubGitHub: GitHubServing, @unchecked Sendable {
        let configureURL = "https://github.com/acme/widgets"
        func fetchRegistrationToken() async throws -> RegistrationToken {
            RegistrationToken(token: "t", expiresAt: .distantFuture)
        }
        func listRunners() async throws -> [GHRunner] { [] }
        func deleteRunner(id: Int) async throws {}
        func queuedJobs(matching labels: Set<String>) async throws -> [QueuedJob] { [] }
        func runningJobs(matching labels: Set<String>) async throws -> [RunningJob] { [] }
    }

    private struct StubTart: TartControlling {
        func list() async throws -> [TartVM] { [] }
        func clone(source: String, to name: String) async throws {}
        func run(name: String, mounts: [String]) async throws {}
        func ip(of name: String, timeout: TimeInterval) async throws -> String { "192.168.64.2" }
        func sshExec(vm: String, user: String, ip: String, script: String, timeout: TimeInterval) async throws -> ShellResult {
            ShellResult(exitCode: 0, stdout: "", stderr: "")
        }
        func stop(name: String) async throws {}
        func delete(name: String) async throws {}
        func pull(image: String) async throws {}
    }

    private struct StubSSH: SSHExecuting {
        func exec(vm: String, user: String, ip: String, script: String, timeout: TimeInterval) async throws -> ShellResult {
            ShellResult(exitCode: 0, stdout: "", stderr: "")
        }
    }

    // MARK: - Helpers

    private func installConfig(_ yaml: String) throws {
        try yaml.write(to: configURL, atomically: true, encoding: .utf8)
    }

    private func loadConfig() throws -> kinhinConfig {
        try ConfigLoader.parse(String(contentsOf: configURL, encoding: .utf8))
    }

    private func makeEngine(_ config: kinhinConfig) -> FleetEngine {
        FleetEngine(
            config: config,
            github: StubGitHub(),
            tart: StubTart(),
            store: FleetStore(directory: scratch.appendingPathComponent("state")),
            ssh: StubSSH(),
            host: host
        )
    }

    private func bucket(
        _ jobs: [ForgeJob],
        config: kinhinConfig
    ) -> [RuntimeID: Int] {
        RuntimeConfigModel(
            config: config.runtimes,
            fleetLabels: config.labels,
            containerLabels: config.container?.labels,
            containerConfigured: config.container != nil
        )
        .demandByPool(for: jobs, forgeID: .github)
    }

    // MARK: - The end-to-end path

    /// CLI `route add` → validated file write → engine reload from that file
    /// → matching job lands in the container pool's demand bucket.
    func testCLIRouteAddReachesEngineDemandBucketing() async throws {
        try installConfig(mixedYAML)
        let engine = try makeEngine(loadConfig())

        // 1. The CLI writes the route (the exact call the command makes; the
        //    only production difference is the config URL and no daemon to
        //    notify).
        try await RuntimesCommand.route(
            ["add", "acme/api", "appleContainer"],
            configURL: configURL,
            notifyDaemon: false
        )

        // 2. The on-disk result is what the reload path reads: route present,
        //    default untouched, and the file still passes engine validation
        //    (the editor already gated it; parse again to prove it).
        let reloaded = try loadConfig()
        XCTAssertEqual(reloaded.runtimes?.routes.first?.pattern, "acme/api")
        XCTAssertEqual(reloaded.runtimes?.routes.first?.runtime, "appleContainer")
        XCTAssertEqual(reloaded.runtimes?.defaultRuntime, "tart", "route add must not disturb the default")

        // 3. A live engine adopts the file — the daemon's reload_config
        //    handler performs exactly this parse + applyReloaded.
        engine.applyReloaded(config: reloaded, host: host)

        // The status shape proves the fleet is now mixed: exact partition
        // caps from the budget split — container 5cpu/14GB ÷ (2cpu, 4GB) = 2;
        // tart remainder 5cpu/14GB ÷ (4cpu, 8GB) = 1 (cpu-bound).
        let status = await engine.status()
        XCTAssertEqual(status.capacityByRuntime?[RuntimeID.appleContainer.rawValue], "2")
        XCTAssertEqual(status.capacityByRuntime?[RuntimeID.tart.rawValue], "1")

        // 4. A queued job from the routed repo must bucket into the container
        //    pool — the same demandByPool call the reconcile loop makes. The
        //    job carries no labels, so the repo route is the only signal.
        let routed = bucket([ForgeJob(name: "build", runnerName: nil, repository: "acme/api")], config: reloaded)
        XCTAssertEqual(routed[.appleContainer], 1, "routed repo lands in the container pool")
        XCTAssertEqual(routed[.tart] ?? 0, 0)

        // A job from an unrouted repo goes the other way — the default pool —
        // proving the route is what moved the first job.
        let unrouted = bucket([ForgeJob(name: "build", runnerName: nil, repository: "acme/other")], config: reloaded)
        XCTAssertEqual(unrouted[.tart], 1)
        XCTAssertEqual(unrouted[.appleContainer] ?? 0, 0)
    }

    /// Same pipeline for removal: after `route remove`, the previously routed
    /// repo falls back to the default pool.
    func testCLIRouteRemoveFallsBackToDefaultPool() async throws {
        try installConfig(mixedYAML)
        try await RuntimesCommand.route(["add", "acme/api", "appleContainer"], configURL: configURL, notifyDaemon: false)
        let engine = try makeEngine(loadConfig())

        // Remove through the CLI, then the running engine picks the file up.
        try await RuntimesCommand.route(["remove", "acme/api"], configURL: configURL, notifyDaemon: false)
        engine.applyReloaded(config: try loadConfig(), host: host)

        // Route gone on disk…
        let yaml = try String(contentsOf: configURL, encoding: .utf8)
        XCTAssertTrue(try RuntimesConfigEditor.parsed(from: yaml)!.routes.isEmpty)

        // …and demand for the same repo now buckets to tart again.
        let config = try loadConfig()
        let buckets = bucket([ForgeJob(name: "build", runnerName: nil, repository: "acme/api")], config: config)
        XCTAssertEqual(buckets[.tart], 1, "after removal the repo uses the default pool")
        XCTAssertEqual(buckets[.appleContainer] ?? 0, 0)
        let status = await engine.status()
        XCTAssertNotNil(status)
    }

    /// A workflow-level route (owner/repo@Name) added by the CLI routes only
    /// that workflow — the same repo's other workflows stay on the default
    /// pool. This is the per-workflow half of the routing contract.
    func testCLIWorkflowRouteBucketsOnlyThatWorkflow() async throws {
        try installConfig(mixedYAML)
        try await RuntimesCommand.route(["add", "acme/api@Nightly", "appleContainer"], configURL: configURL, notifyDaemon: false)

        let config = try loadConfig()
        let buckets = bucket(
            [
                ForgeJob(name: "Nightly", runnerName: nil, repository: "acme/api"),
                ForgeJob(name: "build", runnerName: nil, repository: "acme/api"),
            ],
            config: config
        )
        XCTAssertEqual(buckets[.appleContainer], 1, "only the Nightly workflow is routed")
        XCTAssertEqual(buckets[.tart], 1, "the same repo's other workflow stays on the default pool")
    }

    /// Route-only reload (no `budget:` weights — what a CLI route add on a
    /// plain config produces): there is no split to materialize, so the
    /// default keeps the full-budget cap and other pools carry no cap entry —
    /// selectRuntime's documented "uncapped within the global desired" case.
    /// Routing itself must still work exactly the same.
    func testRouteOnlyReloadCapsTheDefaultAndStillRoutes() async throws {
        try installConfig(baseYAML + "\n" + containerYAML)
        try await RuntimesCommand.route(["add", "acme/api", "appleContainer"], configURL: configURL, notifyDaemon: false)

        let engine = try makeEngine(loadConfig())
        engine.applyReloaded(config: try loadConfig(), host: host)

        let status = await engine.status()
        XCTAssertEqual(Set(status.capacityByRuntime?.keys ?? [:].keys), ["tart"], "only the default has a cap without budget weights")

        // And the route still buckets demand identically.
        let buckets = bucket([ForgeJob(name: "build", runnerName: nil, repository: "acme/api")], config: try loadConfig())
        XCTAssertEqual(buckets[.appleContainer], 1)
        XCTAssertEqual(buckets[.tart] ?? 0, 0)
    }

    /// An invalid route (container runtime with no `container:` section — the
    /// engine's own validation) never reaches an engine: the CLI fails, the
    /// file is byte-identical, and a concurrent reload cannot pick up garbage.
    func testRejectedRouteNeverReachesTheEngine() async throws {
        // Base config without `container:` — adding an appleContainer route
        // is valid YAML but fails engine validation (image required).
        try installConfig(baseYAML)
        let original = try String(contentsOf: configURL, encoding: .utf8)

        do {
            try await RuntimesCommand.route(["add", "acme/api", "appleContainer"], configURL: configURL, notifyDaemon: false)
            XCTFail("engine validation must reject a container route without a container section")
        } catch let error as RuntimesCommand.RouteError {
            XCTAssertTrue(error.message.contains("container"), "got: \(error.message)")
        }

        XCTAssertEqual(try String(contentsOf: configURL, encoding: .utf8), original, "disk untouched on rejection")
        // Parsing yields a config with no routing section — an engine
        // reloading this file keeps its single-pool shape.
        let config = try loadConfig()
        XCTAssertNil(config.runtimes)
    }
}
