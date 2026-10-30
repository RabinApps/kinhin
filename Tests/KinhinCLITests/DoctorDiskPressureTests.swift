import XCTest

@testable import KinhinKit
@testable import kinhin

/// The doctor's disk-pressure advisory (`diskPressure`): the engine's own
/// pre-spawn guard — one instance's footprint + the reserve vs free disk —
/// surfaced before the fleet holds spawns, paired with the image totals and
/// the prune lever. Host and listings are injected; nothing is probed.
final class DoctorDiskPressureTests: XCTestCase {
    /// A working tart-only config (an account keeps it out of the template
    /// scenario, so the config parses and the guard has a shape to plan).
    private static var tartConfig: KinhinConfig {
        var cfg = KinhinConfig.default
        cfg.accounts = [AccountConfig(name: "github", forge: .github, scope: "acme/widgets")]
        return cfg
    }

    private func builder(
        freeDiskGB: Int,
        config: ConfigScenario,
        tartList: [TartVM]? = [],
        containerImages: ImageInventory.RuntimeImages? = nil
    ) -> DoctorReportBuilder {
        DoctorReportBuilder(
            host: HostResources(logicalCores: 10, memoryGB: 32, freeDiskGB: freeDiskGB, arm64: true),
            clt: .ok(version: "26.6"), tartHealth: .healthy, tartList: tartList,
            config: config, authLoad: { _ in nil }, accountLoad: { _, _ in nil },
            containerHealth: containerImages == nil ? nil : .ready,
            containerImages: containerImages,
            fleet: [], projectRecords: [])
    }

    // MARK: - Trigger

    /// Free disk covering the default tart footprint + reserve means no
    /// advisory — and without a parsed config there is no shape to plan, so
    /// the guard never fires.
    func testNoAdvisoryWhenFreeDiskCoversTheNextInstance() async {
        let report = await builder(freeDiskGB: 200, config: .loaded(Self.tartConfig)).build()
        XCTAssertNil(report.diskPressure)
        XCTAssertNil(report.diskPressureLine)

        let noConfig = await builder(freeDiskGB: 1, config: .missing).build()
        XCTAssertNil(noConfig.diskPressure, "no parsed config → nothing to plan against")

        let text = await builder(freeDiskGB: 200, config: .loaded(Self.tartConfig)).buildPlainText()
        XCTAssertFalse(text.contains("WARNING: disk pressure"), text)
    }

    /// Below the guard: the section carries exactly the engine's numbers
    /// (the same ones its spawn-hold message prints).
    func testAdvisoryMirrorsTheEngineGuard() async {
        let report = await builder(freeDiskGB: 40, config: .loaded(Self.tartConfig)).build()
        XCTAssertEqual(
            report.diskPressure,
            DoctorReport.DiskPressureSection(freeGB: 40, runtime: "tart", instanceDiskGB: 50, reserveGB: 10),
            "tart's default footprint is 50 GB, the reserve 10 GB — 40 free < 60 needed")

        let text = await builder(freeDiskGB: 40, config: .loaded(Self.tartConfig)).buildPlainText()
        XCTAssertTrue(
            text.contains(
                "  WARNING: disk pressure — 40 GB free, a new tart instance needs 50 GB + 10 GB reserve"
                    + " — the fleet holds spawns"),
            text)
    }

    /// The config's explicit `disk_gb` replaces the default — the same
    /// number the scaler plans with.
    func testAdvisoryHonorsTheConfiguredDiskFootprint() async {
        var cfg = Self.tartConfig
        cfg.diskGB = 100
        let pressured = await builder(freeDiskGB: 100, config: .loaded(cfg)).build()
        XCTAssertEqual(pressured.diskPressure?.instanceDiskGB, 100, "100 free < 100 + 10 reserve")

        let roomy = await builder(freeDiskGB: 150, config: .loaded(cfg)).build()
        XCTAssertNil(roomy.diskPressure, "150 free ≥ 110 needed")
    }

    /// A Linux-primary fleet plans with the small slot footprint, under the
    /// runtime's own name — the engine's vocabulary.
    func testAdvisoryUsesThePrimaryRuntimeShape() async {
        var cfg = Self.tartConfig
        cfg.container = KinhinConfig.ContainerConfig(image: "kinhin-ci-linux", cpus: 4, memoryGB: 8)
        let report = await builder(
            freeDiskGB: 15, config: .loaded(cfg),
            containerImages: ImageInventory.RuntimeImages(names: ["kinhin-ci-linux:latest"])
        ).build()

        XCTAssertEqual(report.diskPressure?.runtime, "appleContainer")
        XCTAssertEqual(report.diskPressure?.instanceDiskGB, 8, "the container slot default")
    }

    // MARK: - The line (shared with the app's Diagnostics row)

    /// The advisory alone states the guard's numbers; with measured images
    /// it adds what they hold and what the prune would give back — the
    /// lever the user actually has (the fleet can only hold spawns).
    func testLinePairsTheGuardWithTheImageTotalsAndPruneLever() async {
        let withImages = await builder(
            freeDiskGB: 40, config: .loaded(Self.tartConfig),
            tartList: [
                TartVM(name: "tahoe-base", source: "src", status: "stopped", diskGB: 30),
                TartVM(name: "stray-local", source: "src", status: "stopped", diskGB: 12),
            ]
        ).build()
        XCTAssertEqual(withImages.imageTotalGB, ["tart": 42])
        XCTAssertEqual(withImages.imagePrune?.reclaimGB, 12)
        XCTAssertEqual(
            withImages.diskPressureLine,
            "40 GB free, a new tart instance needs 50 GB + 10 GB reserve — the fleet holds spawns"
                + "; images hold 42 GB; up to ~12 GB allocated may be freed with: kinhin image prune")

        let bare = await builder(freeDiskGB: 40, config: .loaded(Self.tartConfig)).build()
        XCTAssertEqual(
            bare.diskPressureLine,
            "40 GB free, a new tart instance needs 50 GB + 10 GB reserve — the fleet holds spawns",
            "no measured images → no image clauses, never a guessed number")
    }

    // MARK: - JSON contract

    func testAdvisoryIsPartOfTheJSONContract() async throws {
        let report = await builder(freeDiskGB: 40, config: .loaded(Self.tartConfig)).build()
        let data = try JSONEncoder().encode(report)
        let json = String(decoding: data, as: UTF8.self)
        XCTAssertTrue(json.contains("\"diskPressure\""), json)
        let decoded = try JSONDecoder().decode(DoctorReport.self, from: data)
        XCTAssertEqual(decoded.diskPressure, report.diskPressure, "the advisory round-trips")
    }
}
