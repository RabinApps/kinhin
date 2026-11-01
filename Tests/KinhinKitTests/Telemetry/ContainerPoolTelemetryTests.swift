import XCTest

@testable import KinhinKit
@testable import KinhinTestSupport

/// Named container pools in telemetry (#75, step 2): Apple container series carry `kinhin.container.pool`, the
/// Apple container queue depth splits by pool, and a pool left out for an unbuilt image shows as a spawn hold.
final class ContainerPoolTelemetryTests: XCTestCase {
    private func makeEngine(
        recorder: RecordingTelemetryBackend, store: FleetStore = makeTestStore(), shell: ContainerFakingShell = .init(),
        pools: Bool = true
    ) -> FleetEngine {
        var config = makeTestConfig()
        config.container = .init(
            image: "kinhin-ci-linux", cpus: 2, memoryGB: 4,
            pools: pools
                ? [
                    .init(name: "big", image: "kinhin-ci-big", cpus: 3, memoryGB: 6, labels: ["linux", "big"]),
                    .init(name: "linux", image: "kinhin-ci-linux", cpus: 2, memoryGB: 4, labels: ["linux"]),
                ] : [])
        var dependencies = FleetEngine.Dependencies(
            tokenLoader: { _, _ in "test-token" }, exitWatchInterval: .milliseconds(20))
        dependencies.telemetry = Telemetry(backend: recorder)
        return FleetEngine(
            config: config, github: FakeGitHub(), tart: FakeTart(), store: store, ssh: FakeSSH(), host: testHost,
            containerShell: shell, dependencies: dependencies)
    }

    private func record(_ id: String, runtime: RuntimeID, pool: String? = nil) -> VMRecord {
        var record = VMRecord(id: id, phase: .ready)
        record.runtimeID = runtime
        record.pool = pool
        record.platform = "github"
        return record
    }

    func testContainerInstancesCarryTheirPool() {
        let store = makeTestStore()
        store.upsert(record("kinhin-1700000000-0000000a", runtime: .appleContainer, pool: "big"))
        store.upsert(record("kinhin-1700000000-0000000b", runtime: .appleContainer))
        store.upsert(record("kinhin-1700000000-0000000c", runtime: .appleContainer, pool: "removed"))
        store.upsert(record("kinhin-1700000000-0000000d", runtime: .tart))
        let engine = makeEngine(recorder: RecordingTelemetryBackend(), store: store)

        XCTAssertEqual(engine.metricAttributes(of: "kinhin-1700000000-0000000a")[Metric.Attr.containerPool], "big")
        XCTAssertEqual(
            engine.metricAttributes(of: "kinhin-1700000000-0000000b")[Metric.Attr.containerPool], "linux",
            "no recorded pool: the default pool")
        XCTAssertEqual(
            engine.metricAttributes(of: "kinhin-1700000000-0000000c")[Metric.Attr.containerPool], "linux",
            "a pool since removed: the default pool")
        XCTAssertNil(engine.metricAttributes(of: "kinhin-1700000000-0000000d")[Metric.Attr.containerPool])
    }

    func testASectionWithoutPoolsAddsNoAttribute() {
        let store = makeTestStore()
        store.upsert(record("kinhin-1700000000-0000000a", runtime: .appleContainer))
        let engine = makeEngine(recorder: RecordingTelemetryBackend(), store: store, pools: false)
        XCTAssertNil(engine.metricAttributes(of: "kinhin-1700000000-0000000a")[Metric.Attr.containerPool])
    }

    func testJobTracesCarryThePool() {
        let store = makeTestStore()
        store.upsert(record("kinhin-1700000000-0000000a", runtime: .appleContainer, pool: "big"))
        let recorder = RecordingTelemetryBackend()
        let engine = makeEngine(recorder: recorder, store: store)

        _ = engine.makeJobTrace(id: "kinhin-1700000000-0000000a")

        let root = recorder.spans(named: "kinhin.job").first
        XCTAssertEqual(root?.attributes[Metric.Attr.containerPool], .string("big"))
    }

    func testWorkerGaugesSplitByPool() async throws {
        let store = makeTestStore()
        store.upsert(record("kinhin-1700000000-0000000a", runtime: .appleContainer, pool: "big"))
        store.upsert(record("kinhin-1700000000-0000000b", runtime: .appleContainer, pool: "linux"))
        store.upsert(record("kinhin-1700000000-0000000c", runtime: .appleContainer, pool: "linux"))
        store.upsert(record("kinhin-1700000000-0000000d", runtime: .tart))
        let recorder = RecordingTelemetryBackend()
        let engine = makeEngine(recorder: recorder, store: store)

        await engine.publishTelemetry()

        let workers = try XCTUnwrap(recorder.gauge(.workers))
        var byPool: [String: Double] = [:]
        for series in workers {
            byPool[series.attributes[Metric.Attr.containerPool] ?? "-", default: 0] += series.value
        }
        XCTAssertEqual(byPool, ["big": 1, "linux": 2, "-": 1], "the tart worker has no container pool")
    }

    func testQueueDepthSplitsTheContainerRuntimeByPool() throws {
        let recorder = RecordingTelemetryBackend()
        let engine = makeEngine(recorder: recorder)

        engine.publishQueueTelemetry(
            byForge: ["github": 4], byPool: [.tart: 1, .appleContainer: 3], byContainerPool: ["big": 1, "linux": 2],
            oldestEnqueuedAt: nil)

        let depths = try XCTUnwrap(recorder.gauge(.queueDepthByPool))
        let keyed = Dictionary(
            uniqueKeysWithValues: depths.map {
                ("\($0.attributes[Metric.Attr.pool] ?? "")/\($0.attributes[Metric.Attr.containerPool] ?? "")", $0.value)
            })
        XCTAssertEqual(keyed, ["tart/": 1, "appleContainer/big": 1, "appleContainer/linux": 2])
    }

    func testQueueDepthWithoutPoolsIsOneSeriesPerRuntime() throws {
        let recorder = RecordingTelemetryBackend()
        let engine = makeEngine(recorder: recorder, pools: false)

        engine.publishQueueTelemetry(byForge: [:], byPool: [.appleContainer: 3], oldestEnqueuedAt: nil)

        let depths = try XCTUnwrap(recorder.gauge(.queueDepthByPool))
        XCTAssertEqual(depths.count, 1)
        XCTAssertEqual(depths.first?.attributes, [Metric.Attr.pool: "appleContainer"])
        XCTAssertEqual(depths.first?.value, 3)
    }

    func testAnUnbuiltPoolIsASpawnHold() async throws {
        let shell = ContainerFakingShell()
        shell.setImages(["kinhin-ci-linux:latest"])
        let recorder = RecordingTelemetryBackend()
        let engine = makeEngine(recorder: recorder, shell: shell)

        _ = await engine.unpreparedContainerPools()
        engine.publishServiceHealth()

        let holds = try XCTUnwrap(recorder.gauge(.spawnHeld))
        XCTAssertEqual(
            holds.map(\.attributes),
            [
                [
                    Metric.Attr.pool: "appleContainer", Metric.Attr.containerPool: "big",
                    Metric.Attr.holdReason: "image_missing",
                ]
            ])
    }
}
