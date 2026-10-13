import Synchronization
import XCTest

@testable import KinhinKit
@testable import KinhinTestSupport

/// The reloadable routing state lives in one `Router` snapshot, and what a
/// hot reload changes (labels, caps) is what the next attach, spawn and
/// scale-set poll read, not the construction-time config.
final class RouterReloadTests: XCTestCase {
    let host = HostResources(logicalCores: 12, memoryGB: 32, freeDiskGB: 200, arm64: true)

    private static func mixedConfig(
        labels: [String] = ["self-hosted", "arm64"], budget: [String: Double] = ["tart": 0.5, "appleContainer": 0.5],
        images: [KinhinConfig.ImageConfig] = []
    ) -> KinhinConfig {
        var cfg = makeTestConfig()
        cfg.labels = labels
        // Small VMs and a generous bound, so the per-runtime caps (not maxRunners) are what limit the pools.
        cfg.maxRunners = 20
        cfg.vm.cpuCount = 1
        cfg.vm.memoryGB = 1
        cfg.container = .init(image: "c", cpus: 1, memoryGB: 4, labels: ["kinhin-container"])
        cfg.images = images
        cfg.runtimes = .init(defaultRuntime: .appleContainer, budget: budget, routes: [])
        return cfg
    }

    private func makeEngine(_ config: KinhinConfig) -> FleetEngine {
        FleetEngine(
            config: config, github: FakeGitHub(), tart: FakeTart(), store: makeTestStore(), ssh: FakeSSH(),
            host: host, dependencies: .init(tokenLoader: { _, _ in "t" }, exitWatchInterval: .milliseconds(20)))
    }

    // MARK: - One atomic snapshot

    /// A reader never sees routes of one config next to images of another:
    /// every snapshot a hammering reader takes is internally consistent.
    func testSnapshotIsNeverTornAcrossConcurrentReplaces() async {
        let host = self.host
        let make: @Sendable (Int) -> Router.Snapshot = { index in
            var cfg = Self.mixedConfig(labels: ["v\(index)"], images: [.init(name: "v\(index)", labels: ["v\(index)"])])
            cfg.projects = []
            return Router.Snapshot.make(config: cfg, host: host)
        }
        let router = Router(make(0))
        let torn = Locked(0)
        let writer = Task {
            for index in 1...400 { router.replace(with: make(index)) }
        }
        let readers = (0..<4).map { _ in
            Task {
                for _ in 0..<400 {
                    let snap = router.snapshot
                    if snap.labels.first != snap.images.first?.name { torn.withLock { $0 += 1 } }
                    if snap.model.pools[.tart]?.labels != snap.labels { torn.withLock { $0 += 1 } }
                }
            }
        }
        await writer.value
        for reader in readers { await reader.value }
        XCTAssertEqual(torn.withLock { $0 }, 0, "labels, images and the routing model swap together")
    }

    /// GitLab filters demand by the labels every pool and image advertises.
    func testServedLabelsAreThePoolAndImageUnion() {
        let cfg = Self.mixedConfig(
            labels: ["self-hosted", "arm64"], images: [.init(name: "xcode-img", labels: ["xcode", "ARM64"])])
        let served = Router.Snapshot.make(config: cfg, host: host).servedLabels
        XCTAssertEqual(Set(served.map { $0.lowercased() }), ["self-hosted", "arm64", "kinhin-container", "xcode"])
        XCTAssertEqual(served.count, 4, "case-insensitive duplicates collapse")
    }

    // MARK: - Reload reaches the next consumer

    func testReloadedLabelsReachTheNextAttach() async {
        let cfg = Self.mixedConfig(labels: ["self-hosted", "arm64"])
        let engine = makeEngine(cfg)
        _ = await engine.attach(account: cfg.accounts[0], token: "t", verify: false)
        XCTAssertEqual(engine.forges["github"]?.labels, ["self-hosted", "arm64"])

        engine.applyReloaded(config: Self.mixedConfig(labels: ["self-hosted", "arm64", "xcode"]), host: host)
        XCTAssertEqual(engine.fleetLabels, ["self-hosted", "arm64", "xcode"])
        XCTAssertEqual(
            engine.forges["github"]?.labels, ["self-hosted", "arm64", "xcode"], "the live forge is relabelled")

        // A fresh attach (a token swap, or the retry of a detached account) uses the reloaded labels,
        // not the frozen `config.labels` the engine was built with.
        engine.forgeState.withLock { $0.byPlatform["github"] = nil }
        _ = await engine.attach(account: cfg.accounts[0], token: "t", verify: false)
        XCTAssertEqual(engine.forges["github"]?.labels, ["self-hosted", "arm64", "xcode"])
        XCTAssertEqual(engine.config.labels, ["self-hosted", "arm64"], "the frozen config itself is untouched")
    }

    func testReloadedLabelsReachANewScaleSetAttach() async {
        var cfg = Self.mixedConfig(labels: ["old"])
        cfg.accounts = [
            AccountConfig(name: "scale", forge: .github, scope: "acme/widgets", scaleSet: .init(name: "kinhin"))
        ]
        let engine = makeEngine(cfg)
        engine.applyReloaded(config: Self.mixedConfig(labels: ["new"]), host: host)
        _ = await engine.attach(account: cfg.accounts[0], token: "t", verify: false)
        XCTAssertEqual(engine.forges["scale"]?.labels, ["new"])
    }

    func testReloadedLabelsReachTheNextSpawnsPoolLabels() {
        let engine = makeEngine(Self.mixedConfig(labels: ["self-hosted", "arm64"]))
        var record = VMRecord(id: "kinhin-1", phase: .cloning)
        record.runtimeID = .tart
        XCTAssertEqual(engine.poolLabels(for: record), ["self-hosted", "arm64"])
        engine.applyReloaded(config: Self.mixedConfig(labels: ["self-hosted", "arm64", "gpu"]), host: host)
        XCTAssertEqual(engine.poolLabels(for: record), ["self-hosted", "arm64", "gpu"])
    }

    func testReloadedCapsReachTheNextScalePlan() async throws {
        let cfg = Self.mixedConfig(budget: ["tart": 0.5, "appleContainer": 0.5])
        let engine = makeEngine(cfg)
        _ = await engine.attach(account: cfg.accounts[0], token: "t", verify: false)
        let attached = Array(engine.forges.values)
        var demand = FleetEngine.Demand()
        demand.queueDepth = 50
        demand.byForge["github"] = 50
        demand.byPool[.tart] = 50
        demand.byForgePool["github"] = [.tart: 50]

        let before = engine.scalePlan(demand: demand, attached: attached).slots.filter { $0.runtime == .tart }.count
        XCTAssertEqual(before, min(engine.capsByRuntime[.tart] ?? 0, engine.capacity.maxConcurrent))
        engine.applyReloaded(config: Self.mixedConfig(budget: ["tart": 0.9, "appleContainer": 0.1]), host: host)
        let after = engine.scalePlan(demand: demand, attached: attached).slots.filter { $0.runtime == .tart }.count
        XCTAssertEqual(after, min(engine.capsByRuntime[.tart] ?? 0, engine.capacity.maxConcurrent))
        XCTAssertGreaterThan(after, before, "the next pass spawns up to the reloaded cap")
    }

    // MARK: - Scale-set listener capacity follows reloads

    func testScaleSetListenerCapacityFollowsReloadedCaps() async throws {
        var cfg = Self.mixedConfig(budget: ["tart": 0.5, "appleContainer": 0.5])
        cfg.accounts = [
            AccountConfig(name: "scale", forge: .github, scope: "acme/widgets", scaleSet: .init(name: "kinhin"))
        ]
        let engine = makeEngine(cfg)
        _ = await engine.attach(account: cfg.accounts[0], token: "t", verify: false)
        let forge = try XCTUnwrap(engine.forges["scale"] as? GitHubScaleSetForge)
        let tartTarget = try XCTUnwrap(forge.targets.first { $0.runtime == .tart })
        let containerTarget = try XCTUnwrap(forge.targets.first { $0.runtime == .appleContainer })

        let tartBefore = tartTarget.listener.maxCapacity()
        let containerBefore = containerTarget.listener.maxCapacity()
        XCTAssertEqual(tartBefore, engine.scaleSetJobCapacity(for: .tart))
        XCTAssertGreaterThan(tartBefore, 0)

        engine.applyReloaded(
            config: Self.mixedConfig(budget: ["tart": 0.9, "appleContainer": 0.1]).withAccounts(cfg.accounts),
            host: host)

        let tartAfter = tartTarget.listener.maxCapacity()
        let containerAfter = containerTarget.listener.maxCapacity()
        XCTAssertGreaterThan(tartAfter, tartBefore, "the open listener asks GitHub for the reloaded tart cap")
        XCTAssertLessThan(containerAfter, containerBefore, "and for the shrunken container cap")
    }

    func testSingleListenerCapacityKeepsTheFleetCapWithoutPartitioning() {
        var cfg = makeTestConfig()
        cfg.maxRunners = 4
        cfg.runnersPerVM = 2
        let engine = makeEngine(cfg)
        let expected =
            min(4, engine.capacity.maxConcurrent) * 2
        XCTAssertEqual(engine.scaleSetJobCapacity(for: .tart), expected)
    }
}

extension KinhinConfig {
    fileprivate func withAccounts(_ accounts: [AccountConfig]) -> KinhinConfig {
        var copy = self
        copy.accounts = accounts
        return copy
    }
}
