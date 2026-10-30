import Foundation
import XCTest

@testable import KinhinKit
@testable import KinhinTestSupport

/// Image bake, toolchain cache and runner disk metrics.
final class TelemetryImageCacheDiskTests: XCTestCase {
    private var scratch: URL!

    override func setUpWithError() throws {
        scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("kinhin-telemetry-icd-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: scratch)  // test temp dir
    }

    private func makeEngine(
        _ recorder: RecordingTelemetryBackend?, tart: FakeTart = FakeTart(), config: KinhinConfig = makeTestConfig(),
        bake: ProjectImageBuilder.Bake? = nil
    ) -> FleetEngine {
        var dependencies = FleetEngine.Dependencies(tokenLoader: { _, _ in "t" }, exitWatchInterval: .milliseconds(20))
        if let recorder { dependencies.telemetry = Telemetry(backend: recorder) }
        let images = scratch.appendingPathComponent("images", isDirectory: true)
        try? FileManager.default.createDirectory(at: images, withIntermediateDirectories: true)
        dependencies.projectImageStore = ProjectImageStore(directory: images)
        dependencies.projectBake = bake
        return FleetEngine(
            config: config, github: FakeGitHub(), tart: tart, store: makeTestStore(), ssh: FakeSSH(), host: testHost,
            dependencies: dependencies)
    }

    private func toolchains(_ spec: String) -> KinhinConfig.ToolchainsConfig {
        var value = KinhinConfig.ToolchainsConfig()
        value.specs = [spec]
        return value
    }

    // MARK: - Image bakes

    func testSuccessfulBakeRecordsDurationAndCount() async throws {
        let recorder = RecordingTelemetryBackend()
        let tart = FakeTart()
        let engine = makeEngine(
            recorder, tart: tart,
            bake: { options in
                try await Task.sleep(for: .milliseconds(30))
                tart.vms[options.target] = TartVM(name: options.target, source: "local", status: "stopped")
            })
        let first = try await engine.projectImages.request(toolchains: toolchains("go@1.22.5"), shareCache: false)
        guard case .building(let name) = first else { return XCTFail("expected a bake to start, got \(first)") }
        await engine.projectImages.waitForBakes()

        let counts = recorder.counters.filter { $0.name == Metric.Counter.imageBakes.rawValue }
        XCTAssertEqual(counts.count, 1)
        XCTAssertEqual(counts.first?.value, 1)
        XCTAssertEqual(counts.first?.attributes, [Metric.Attr.image: name, Metric.Attr.outcome: "success"])
        let timings = recorder.histograms(.imageBakeDuration)
        XCTAssertEqual(timings.count, 1)
        XCTAssertGreaterThanOrEqual(try XCTUnwrap(timings.first?.seconds), 0.02)
        XCTAssertEqual(timings.first?.attributes, counts.first?.attributes, "one bounded attribute set for both")
    }

    func testFailedBakeCountsAsFailureWithBoundedAttributes() async throws {
        struct Boom: LocalizedError { var errorDescription: String? { "disk full at /private/path/secret-123" } }
        let recorder = RecordingTelemetryBackend()
        let engine = makeEngine(recorder, bake: { _ in throw Boom() })
        _ = try await engine.projectImages.request(toolchains: toolchains("node@20"), shareCache: false)
        await engine.projectImages.waitForBakes()

        XCTAssertEqual(recorder.counterTotal(.imageBakes) { $0[Metric.Attr.outcome] == "failure" }, 1)
        XCTAssertEqual(recorder.counterTotal(.imageBakes) { $0[Metric.Attr.outcome] == "success" }, 0)
        XCTAssertEqual(recorder.histograms(.imageBakeDuration).count, 1, "a failed bake still has a duration")
        for sample in recorder.counters {
            XCTAssertEqual(Set(sample.attributes.keys), [Metric.Attr.image, Metric.Attr.outcome])
            XCTAssertFalse(sample.attributes.values.contains { $0.contains("secret") }, "no error text as a dimension")
        }
    }

    func testCancelledBakeIsNeitherSuccessNorFailure() async throws {
        let recorder = RecordingTelemetryBackend()
        let engine = makeEngine(recorder, bake: { _ in throw CancellationError() })
        _ = try await engine.projectImages.request(toolchains: toolchains("go@1.22.5"), shareCache: false)
        await engine.projectImages.waitForBakes()
        XCTAssertEqual(recorder.counterTotal(.imageBakes), 0)
        XCTAssertTrue(recorder.histograms(.imageBakeDuration).isEmpty)
    }

    func testBakeWithTelemetryOffRecordsNothingAndStillBakes() async throws {
        let tart = FakeTart()
        let baked = Locked(0)
        let engine = makeEngine(
            nil, tart: tart,
            bake: { options in
                baked.withLock { $0 += 1 }
                tart.vms[options.target] = TartVM(name: options.target, source: "local", status: "stopped")
            })
        _ = try await engine.projectImages.request(toolchains: toolchains("go@1.22.5"), shareCache: false)
        await engine.projectImages.waitForBakes()
        XCTAssertEqual(baked.withLock { $0 }, 1)
    }

    func testBakeMetricsAreRegisteredInTheCatalog() {
        XCTAssertEqual(Metric.Counter.imageBakes.rawValue, "kinhin.image.bakes")
        XCTAssertEqual(Metric.Histogram.imageBakeDuration.rawValue, "kinhin.image.bake.duration")
        XCTAssertEqual(Metric.Counter.cachePrunes.rawValue, "kinhin.cache.prunes")
        XCTAssertEqual(Metric.Gauge.cacheSize.rawValue, "kinhin.cache.size")
        XCTAssertEqual(Metric.Gauge.runnerDiskUsage.rawValue, "kinhin.runner.disk.usage")
    }

    // MARK: - Toolchain cache

    private func writeOld(_ name: String, bytes: Int, ageDays: Double, in root: URL) throws {
        let url = root.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(repeating: 0x41, count: bytes).write(to: url)
        try FileManager.default.setAttributes(
            [.modificationDate: Date().addingTimeInterval(-ageDays * 86_400)], ofItemAtPath: url.path)
    }

    func testCacheSweepPublishesSizeAfterPruneAndCountsOnePrune() async throws {
        let recorder = RecordingTelemetryBackend()
        let root = scratch.appendingPathComponent("cache", isDirectory: true)
        try writeOld("npm/old.tar", bytes: 300, ageDays: 90, in: root)
        try writeOld("npm/new.tar", bytes: 100, ageDays: 1, in: root)
        let engine = makeEngine(recorder)
        await engine.publishTelemetry()
        XCTAssertEqual(recorder.gauge(.cacheSize)?.count, 0, "no sweep yet: unavailable, not zero")

        await engine.runCacheSweep(pruner: ToolchainCachePruner(cacheRoot: root))
        XCTAssertEqual(
            recorder.counters.filter { $0.name == Metric.Counter.cachePrunes.rawValue }.map(\.attributes),
            [[Metric.Attr.outcome: "success"]])
        await engine.publishTelemetry()
        let series = try XCTUnwrap(recorder.gauge(.cacheSize))
        XCTAssertEqual(series.count, 1)
        XCTAssertEqual(series.first?.value, 100, "the size after pruning the old entry")
        XCTAssertEqual(series.first?.attributes, [Metric.Attr.cache: "toolchain"])

        // Publishing again does not walk or count again.
        await engine.publishTelemetry()
        XCTAssertEqual(recorder.counterTotal(.cachePrunes), 1)
    }

    func testCacheSizeIsStillMeasuredWithAutoPruneOffButNoPruneIsCounted() async throws {
        let recorder = RecordingTelemetryBackend()
        let root = scratch.appendingPathComponent("cache", isDirectory: true)
        try writeOld("go/mod.zip", bytes: 250, ageDays: 90, in: root)
        var config = makeTestConfig()
        config.toolchainCache = .init(autoPrune: false)
        let engine = makeEngine(recorder, config: config)
        await engine.runCacheSweep(pruner: ToolchainCachePruner(cacheRoot: root))
        await engine.publishTelemetry()
        XCTAssertEqual(recorder.gauge(.cacheSize)?.first?.value, 250)
        XCTAssertEqual(recorder.counterTotal(.cachePrunes), 0)
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("go/mod.zip").path))
    }

    func testMissingCacheDirectoryPublishesNoSizeAndCountsNoPrune() async {
        let recorder = RecordingTelemetryBackend()
        let engine = makeEngine(recorder)
        await engine.runCacheSweep(pruner: ToolchainCachePruner(cacheRoot: scratch.appendingPathComponent("absent")))
        await engine.publishTelemetry()
        XCTAssertEqual(recorder.gauge(.cacheSize)?.count, 0, "no cache, no series: absent, never zero")
        XCTAssertEqual(recorder.counterTotal(.cachePrunes), 0)
    }

    func testFailedDeletionCountsAsFailure() {
        let recorder = RecordingTelemetryBackend()
        let engine = makeEngine(recorder)
        engine.noteCacheSweep(
            report: ToolchainPruneReport(
                entries: [], freedBytes: 0, dryRun: false, failedCount: 2, remainingBytes: 10), totalBytes: 10)
        XCTAssertEqual(recorder.counterTotal(.cachePrunes) { $0[Metric.Attr.outcome] == "failure" }, 1)
        // A dry run is not a prune.
        engine.noteCacheSweep(
            report: ToolchainPruneReport(entries: [], freedBytes: 0, dryRun: true, remainingBytes: 10), totalBytes: 10)
        XCTAssertEqual(recorder.counterTotal(.cachePrunes), 1)
    }

    func testPrunerReportsRemainingBytes() throws {
        let root = scratch.appendingPathComponent("cache", isDirectory: true)
        try writeOld("npm/old.tar", bytes: 300, ageDays: 90, in: root)
        try writeOld("npm/new.tar", bytes: 100, ageDays: 1, in: root)
        let pruner = ToolchainCachePruner(cacheRoot: root)
        XCTAssertEqual(pruner.measuredBytes(), 400)
        let report = pruner.prune(policy: ToolchainCachePolicy(autoPrune: true, maxAgeDays: 30, maxGB: 0))
        XCTAssertEqual(report.remainingBytes, 100)
        XCTAssertEqual(report.failedCount, 0)
        XCTAssertNil(ToolchainCachePruner(cacheRoot: scratch.appendingPathComponent("none")).measuredBytes())
    }

    // MARK: - Runner disk

    func testTartListParsesOnDiskSize() throws {
        let json = """
            [{"State":"running","Disk":50,"Source":"local","Size":20,"SizeOnDisk":12,"Name":"a","Running":true},
             {"State":"stopped","Disk":50,"Source":"local","Size":40,"Name":"b","Running":false},
             {"State":"stopped","Disk":50,"Source":"local","Name":"c","Running":false}]
            """
        let vms = try TartController.parseListJSON(json)
        XCTAssertEqual(vms.map(\.sizeGB), [12, 40, nil], "SizeOnDisk first, then Size; absent stays nil")
        XCTAssertEqual(vms.map(\.diskGB), [50, 50, 50])
    }

    func testResourceUsageDecodesWithoutDiskField() throws {
        let old = Data(#"{"cpuPercent":12.5,"memoryUsedMB":512}"#.utf8)
        let usage = try JSONDecoder().decode(ResourceUsage.self, from: old)
        XCTAssertEqual(usage.memoryUsedMB, 512)
        XCTAssertNil(usage.diskUsedGB)
        let round = try JSONDecoder().decode(
            ResourceUsage.self, from: JSONEncoder().encode(ResourceUsage(diskUsedGB: 7)))
        XCTAssertEqual(round.diskUsedGB, 7)
    }

    func testSamplerCarriesDiskAndLeavesItNilWhenTartCannotSay() async {
        let tart = FakeTart()
        tart.vms["kinhin-1"] = TartVM(name: "kinhin-1", source: "local", status: "running", diskGB: 50, sizeGB: 9)
        tart.vms["kinhin-2"] = TartVM(name: "kinhin-2", source: "local", status: "running", diskGB: 50)
        tart.processSampleValues = [
            "kinhin-1": ProcessSample(rssMB: 100, cpuSeconds: 1), "kinhin-2": ProcessSample(rssMB: 100, cpuSeconds: 1),
        ]
        let sampler = UsageSampler(
            tart: tart, shell: FakeShell(), tartMemoryMB: { 4096 }, minInterval: .milliseconds(0))
        let records = [
            VMRecord(id: "kinhin-1", phase: .ready, createdAt: Date()),
            VMRecord(id: "kinhin-2", phase: .ready, createdAt: Date()),
        ]
        let snapshot = await sampler.snapshot(for: records)
        XCTAssertEqual(snapshot.byInstance["kinhin-1"]?.diskUsedGB, 9)
        XCTAssertNotNil(snapshot.byInstance["kinhin-2"])
        XCTAssertNil(snapshot.byInstance["kinhin-2"]?.diskUsedGB, "unavailable stays nil, never zero")

        tart.failList = true
        let failed = await UsageSampler(
            tart: tart, shell: FakeShell(), tartMemoryMB: { 4096 }, minInterval: .milliseconds(0)
        ).snapshot(for: records)
        XCTAssertNotNil(failed.byInstance["kinhin-1"]?.memoryUsedMB)
        XCTAssertNil(failed.byInstance["kinhin-1"]?.diskUsedGB)
    }

    func testRunnerDiskIsAggregatedPerPoolAndImageNeverPerVM() async throws {
        let recorder = RecordingTelemetryBackend()
        let tart = FakeTart()
        let engine = makeEngine(recorder, tart: tart)
        for id in ["kinhin-a", "kinhin-b", "kinhin-c"] {
            engine.store.upsert(VMRecord(id: id, phase: .ready, createdAt: Date()))
        }
        tart.vms["kinhin-a"] = TartVM(name: "kinhin-a", source: "local", status: "running", sizeGB: 10)
        tart.vms["kinhin-b"] = TartVM(name: "kinhin-b", source: "local", status: "running", sizeGB: 5)
        tart.vms["kinhin-c"] = TartVM(name: "kinhin-c", source: "local", status: "running")  // no size
        tart.processSampleValues = Dictionary(
            uniqueKeysWithValues: ["kinhin-a", "kinhin-b", "kinhin-c"].map {
                ($0, ProcessSample(rssMB: 10, cpuSeconds: 1))
            })
        await engine.publishTelemetry()

        let series = try XCTUnwrap(recorder.gauge(.runnerDiskUsage))
        XCTAssertEqual(series.count, 1, "one series per pool and image, not per VM")
        XCTAssertEqual(series[0].value, 15_000_000_000)
        XCTAssertEqual(Set(series[0].attributes.keys), [Metric.Attr.pool, Metric.Attr.image])
        XCTAssertFalse(series[0].attributes.values.contains { $0.hasPrefix(InstanceNaming.prefix) })
    }

    func testRunnerDiskAbsentWhenNoRuntimeSuppliesIt() async {
        let recorder = RecordingTelemetryBackend()
        let tart = FakeTart()
        let engine = makeEngine(recorder, tart: tart)
        engine.store.upsert(VMRecord(id: "kinhin-a", phase: .ready, createdAt: Date()))
        tart.vms["kinhin-a"] = TartVM(name: "kinhin-a", source: "local", status: "running")
        tart.processSampleValues = ["kinhin-a": ProcessSample(rssMB: 10, cpuSeconds: 1)]
        await engine.publishTelemetry()
        XCTAssertEqual(recorder.gauge(.runnerDiskUsage)?.count, 0, "no on-disk size: no series, never zero")
    }
}
