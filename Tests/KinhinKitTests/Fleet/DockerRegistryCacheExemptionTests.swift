import XCTest

@testable import KinhinKit
@testable import KinhinTestSupport

/// The Docker Hub cache container is not a runner: recovery never adopts it, the orphan sweep never removes it, image
/// usage and capacity never count it, the app's Containers view does not mark it as a CI job, and `kinhin image prune`
/// keeps its `registry:3` image while a pool uses the cache.
final class DockerRegistryCacheExemptionTests: XCTestCase {
    private let cache = DockerRegistryCache.containerName
    private let orphan = "kinhin-1717000000-a1b2c3d4"

    private func makeEngine(_ shell: ContainerFakingShell) -> FleetEngine {
        var config = makeTestConfig()
        config.container = .init(image: "kinhin-ci-linux", cpus: 2, memoryGB: 4, docker: true)
        var dependencies = FleetEngine.Dependencies(
            tokenLoader: { _, _ in "test-token" }, exitWatchInterval: .milliseconds(20),
            watchdog: Watchdog(orphanSweepInterval: .zero, orphanGrace: .zero))
        dependencies.registryCacheDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("exemption-registry-cache-\(UUID().uuidString)", isDirectory: true)
        return FleetEngine(
            config: config, github: FakeGitHub(), tart: FakeTart(), store: makeTestStore(), ssh: FakeSSH(),
            host: testHost, containerShell: shell, dependencies: dependencies)
    }

    /// A shell on which the cache and an orphaned runner container both exist.
    private func shellWithTheCacheAndAnOrphan() async throws -> ContainerFakingShell {
        let shell = ContainerFakingShell()
        for name in [cache, orphan] {
            _ = try await shell.run(
                ["/usr/local/bin/container", "run", "--detach", "--name", name, "image"], cwd: nil, timeout: 5)
        }
        return shell
    }

    private func deleted(_ shell: ContainerFakingShell) -> [String] {
        shell.argvSnapshot().filter { $0.dropFirst().first == "delete" }.compactMap(\.last)
    }

    func testItsNameIsNoRunnerName() {
        XCTAssertFalse(InstanceNaming.isOurs(cache), "recovery and image usage only look at kinhin- names")
        XCTAssertFalse(FleetEngine.isGeneratedInstanceName(cache), "the orphan sweep only removes generated names")
        XCTAssertFalse(
            ManagedContainer(id: cache, name: cache, image: DockerRegistryCache.image, state: "running").isKinhinRunner,
            "the Containers view does not warn that deleting it cancels a job")
    }

    func testTheOrphanSweepLeavesItAlone() async throws {
        let shell = try await shellWithTheCacheAndAnOrphan()
        let engine = makeEngine(shell)
        let start = Date()
        await engine.sweepOrphans(now: start)
        await engine.sweepOrphans(now: start.addingTimeInterval(60))
        XCTAssertEqual(deleted(shell), [orphan], "the orphaned runner goes, the cache stays")
    }

    func testRecoveryNeverAdoptsIt() async throws {
        let shell = try await shellWithTheCacheAndAnOrphan()
        let engine = makeEngine(shell)
        await engine.recoverIfNeeded()
        let ids = engine.store.all.map(\.id)
        XCTAssertFalse(ids.contains(cache), "no record, so no capacity slot and no forge registration: \(ids)")
        XCTAssertFalse(deleted(shell).contains(cache))
        XCTAssertFalse(
            shell.argvSnapshot().contains { $0.dropFirst().first == "stop" && $0.contains(cache) }, "never stopped")
    }

    func testImageUsageDoesNotCountItAsARunner() async throws {
        let listed = try await ImageInventory.withInstances(
            .init(names: [DockerRegistryCache.image]), runtime: .container
        ) { [cache, orphan] in [cache, orphan] }
        XCTAssertEqual(listed.instances, [orphan])
    }

    // MARK: - image prune

    private func config(docker: Bool, cache: Bool = true) -> KinhinConfig {
        var cfg = KinhinConfig.default
        cfg.image = "tahoe-base"
        cfg.container = .init(image: "kinhin-ci-linux", docker: docker, dockerCache: cache)
        return cfg
    }

    private func pruneTargets(_ cfg: KinhinConfig) -> [String] {
        let inventory = ImageInventory.build(
            config: cfg, tart: .init(names: ["tahoe-base"]),
            container: .init(names: ["kinhin-ci-linux:latest", DockerRegistryCache.image, "old:1"]))
        return ImagePrunePlan.plan(inventory: inventory, config: cfg).targets.map(\.name)
    }

    func testPruneKeepsTheCachesImageWhileAPoolUsesIt() {
        XCTAssertEqual(pruneTargets(config(docker: true)), ["old:1"])
    }

    func testPruneKeepsItWhenOnlyANamedPoolUsesIt() {
        var cfg = config(docker: false)
        cfg.container?.pools = [
            .init(name: "plain", image: "kinhin-ci-linux", labels: ["plain"]),
            .init(name: "dind", image: "kinhin-ci-linux", labels: ["dind"], docker: true),
        ]
        XCTAssertEqual(pruneTargets(cfg), ["old:1"])
    }

    func testPruneMayTakeItOnceNothingUsesTheCache() {
        XCTAssertEqual(pruneTargets(config(docker: false)), ["old:1", DockerRegistryCache.image].sorted())
        XCTAssertEqual(pruneTargets(config(docker: true, cache: false)), ["old:1", DockerRegistryCache.image].sorted())
    }
}
