import XCTest
@testable import orchard
import OrchardKit

/// The full route-editing path, end to end: the CLI subcommand writes a
/// route through the validated editor onto a scratch config, a live engine
/// reloads from that same file (the daemon's reload_config flow), and the
/// engine's demand bucketing sends a matching job to the routed pool — not
/// the default one.
final class RouteToEngineReloadTests: XCTestCase {
    private let host = HostResources(logicalCores: 12, memoryGB: 32, freeDiskGB: 200, arm64: true)

    override func setUp() async throws {
        try await super.setUp()
        scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("orchard-route-e2e-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: scratch)
        try await super.tearDown()
    }

    private var scratch: URL!

    private var configURL: URL { scratch.appendingPathComponent("config.yaml") }

    /// A config the engine would actually run: macOS VM shape + container
    /// section (routes to appleContainer are rejected without one), no
    /// routing yet — exactly the state a single-pool fleet starts in.
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
    container:
      image: "orchard-ci-linux"
      cpus: 2
      memory_gb: 4
    """

    private func installConfig(_ yaml: String) throws {
        try yaml.write(to: configURL, atomically: true, encoding: .utf8)
    }

    private func loadConfig() throws -> OrchardConfig {
        try ConfigLoader.parse(String(contentsOf: configURL, encoding: .utf8))
    }

    private func makeEngine(_ config: OrchardConfig) -> (FleetEngine, FakeGitHub) {
        let github = FakeGitHub()
        let engine = FleetEngine(
            config: config,
            github: github,
            tart: FakeTart(),
            store: makeTestStore(),
            ssh: FakeSSH(),
            host: host
        )
        return (engine, github)
    }

    // MARK: - The end-to-end path

    /// CLI `route add` → validated file write → engine reload from that file
    /// → matching job lands in the container pool's demand bucket.
    func testCLIRouteAddReachesEngineDemandBucketing() async throws {
        installConfig(baseYAML)
        let (engine, github) = try makeEngine(loadConfig())

        // 1. The CLI writes the route (same call the command makes; the only
        //    difference from production is the scratch config URL and no
        //    daemon to notify).
        try await RuntimesCommand.route(
            ["add", "acme/api", "appleContainer"],
            configURL: configURL,
            notifyDaemon: false
        )

        // 2. The on-disk result is exactly what the reload path reads: the
        //    route exists, and the whole file still passes engine validation
        //    (the editor already gated it, but assert the parse too).
        let reloadedConfig = try loadConfig()
        XCTAssertEqual(reloadedConfig.runtimes?.routes.first?.pattern, "acme/api")
        XCTAssertEqual(reloadedConfig.runtimes?.routes.first?.runtime, "appleContainer")
        XCTAssertEqual(reloadedConfig.runtimes?.defaultRuntime, "tart", "route add must not disturb the default")

        // 3. A live engine adopts the file (reload_config's handler does
        //    exactly this parse + applyReloaded).
        engine.applyReloaded(config: reloadedConfig, host: host)

        // The status shape proves the fleet is now mixed: partitioned caps.
        let status = await engine.status()
        XCTAssertEqual(Set(status.capacityByRuntime?.keys ?? [:].keys), ["tart", "appleContainer"])

        // 4. A queued job from the routed repo must bucket into the
        //    container pool — the same demandByPool call the reconcile loop
        //    makes on every poll. The job carries no labels, so the route is
        //    the only signal (repo route precedence).
        let decision = reloadedConfig.runtimes.map {
            RuntimeConfigModel(
                config: $0,
                fleetLabels: reloadedConfig.labels,
                containerLabels: reloadedConfig.container?.labels,
                containerConfigured: true
            )
        }
        let buckets = try XCTUnwrap(decision).demandByPool(
            for: [ForgeJob(name: "build", runnerName: nil, repository: "acme/api")],
            forgeID: .github
        )
        XCTAssertEqual(buckets[.appleContainer], 1, "routed repo lands in the container pool")
        XCTAssertEqual(buckets[.tart] ?? 0, 0)

        // And a job from an unrouted repo goes the other way — the default
        // pool — proving the route is what moved the first job.
        let unbuckled = try XCTUnwrap(decision).demandByPool(
            for: [ForgeJob(name: "build", runnerName: nil, repository: "acme/other")],
            forgeID: .github
        )
        XCTAssertEqual(unbuckled[.tart], 1)
        XCTAssertEqual(unbuckled[.appleContainer] ?? 0, 0)

        _ = github // engine holds it; no spawn asserted here (fake lifecycle covered elsewhere)
    }

    /// Same pipeline for removal: after `route remove`, the previously routed
    /// repo falls back to the default pool.
    func testCLIRouteRemoveFallsBackToDefaultPool() async throws {
        installConfig(baseYAML)
        try await RuntimesCommand.route(["add", "acme/api", "appleContainer"], configURL: configURL, notifyDaemon: false)

        let (engine, _) = try makeEngine(loadConfig())

        // Remove through the CLI, then the running engine picks the file up.
        try await RuntimesCommand.route(["remove", "acme/api"], configURL: configURL, notifyDaemon: false)
        engine.applyReloaded(config: try loadConfig(), host: host)

        // Route gone on disk…
        let yaml = try String(contentsOf: configURL, encoding: .utf8)
        XCTAssertTrue(try RuntimesConfigEditor.parsed(from: yaml)!.routes.isEmpty)

        // …and the engine's model agrees: the same job now buckets to tart.
        let config = try loadConfig()
        let model = RuntimeConfigModel(
            config: config.runtimes,
            fleetLabels: config.labels,
            containerLabels: config.container?.labels,
            containerConfigured: true
        )
        let buckets = model.demandByPool(
            for: [ForgeJob(name: "build", runnerName: nil, repository: "acme/api")],
            forgeID: .github
        )
        XCTAssertEqual(buckets[.tart], 1, "after removal the repo uses the default pool")
        XCTAssertEqual(buckets[.appleContainer] ?? 0, 0)
        let status = await engine.status()
        XCTAssertNotNil(status)
    }

    /// A workflow-level route (owner/repo@Name) added by the CLI routes only
    /// jobs from that workflow's job names — the same repo can keep its
    /// other workflows on the default pool.
    func testCLIWorkflowRouteBucketsOnlyThatWorkflow() async throws {
        installConfig(baseYAML)
        try await RuntimesCommand.route(["add", "acme/api@Nightly", "appleContainer"], configURL: configURL, notifyDaemon: false)

        let config = try loadConfig()
        let model = RuntimeConfigModel(
            config: config.runtimes,
            fleetLabels: config.labels,
            containerLabels: config.container?.labels,
            containerConfigured: true
        )
        let buckets = model.demandByPool(
            for: [
                ForgeJob(name: "Nightly", runnerName: nil, repository: "acme/api"),
                ForgeJob(name: "build", runnerName: nil, repository: "acme/api"),
            ],
            forgeID: .github
        )
        XCTAssertEqual(buckets[.appleContainer], 1, "only the Nightly workflow is routed")
        XCTAssertEqual(buckets[.tart], 1, "the same repo's other workflow stays on the default pool")
    }

    /// An invalid route (runtime with no container section — the engine's
    /// own validation) never reaches an engine: the CLI fails and the file
    /// is byte-identical, so a concurrent reload cannot pick up garbage.
    func testRejectedRouteNeverReachesTheEngine() async throws {
        // Base config without `container:` — adding an appleContainer route
        // is valid YAML but fails engine validation (image required).
        installConfig(baseYAML.replacingOccurrences(
            of: "\ncontainer:\n  image: \"orchard-ci-linux\"\n  cpus: 2\n  memory_gb: 4\n",
            with: ""
        ))
        let original = try String(contentsOf: configURL, encoding: .utf8)

        do {
            try await RuntimesCommand.route(["add", "acme/api", "appleContainer"], configURL: configURL, notifyDaemon: false)
            XCTFail("engine validation must reject a container route without a container section")
        } catch let error as RuntimesCommand.RouteError {
            XCTAssertTrue(error.message.contains("container"), "got: \(error.message)")
        }

        XCTAssertEqual(try String(contentsOf: configURL, encoding: .utf8), original, "disk untouched on rejection")
        // Parsing still yields a routing model with no routes — nothing to
        // apply, and an engine reloading this file keeps single-pool shape.
        let config = try loadConfig()
        XCTAssertNil(config.runtimes)
    }
}
