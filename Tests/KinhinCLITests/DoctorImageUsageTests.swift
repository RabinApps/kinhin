import XCTest

@testable import KinhinKit
@testable import kinhin

/// The doctor's image surface: the per-runtime disk-usage breakdown
/// (`imageTotalGB`) and the prune suggestion (`imagePrune`) — the same totals
/// `kinhin image list` prints, and the sweep `kinhin image prune` would run,
/// surfaced in the diagnostics document, the human report and (via the shared
/// line formatters) the app's Diagnostics tab. Every listing and both stores
/// are injected — nothing is probed.
final class DoctorImageUsageTests: XCTestCase {
    private let host = HostResources(logicalCores: 10, memoryGB: 32, freeDiskGB: 200, arm64: true)

    /// A config enabling both Linux runtimes (their sections are declared,
    /// so every listing below must be injected — an un-injected one would
    /// probe the real runtime). It carries an account so the scenario
    /// resolves as a working config, not the starter template.
    private static var linuxConfig: KinhinConfig {
        var cfg = KinhinConfig.default
        cfg.accounts = [AccountConfig(name: "github", forge: .github, scope: "acme/widgets")]
        cfg.container = KinhinConfig.ContainerConfig(image: "kinhin-ci-linux", cpus: 4, memoryGB: 8)
        cfg.docker = KinhinConfig.DockerForgeConfig(image: "ci")
        return cfg
    }

    /// A tart-only config: nothing declares a Linux runtime, so no listing
    /// beyond the injected tart one is wanted.
    private static var tartOnlyConfig: KinhinConfig {
        var cfg = KinhinConfig.default
        cfg.accounts = [AccountConfig(name: "github", forge: .github, scope: "acme/widgets")]
        return cfg
    }

    /// The sized tart listing every breakdown test starts from: the base
    /// image, a derived image, and a runner VM clone that must NOT count —
    /// the totals cover images, not what the fleet is running right now.
    private var tartImages: [TartVM] {
        [
            TartVM(
                name: "tahoe-base", source: "ghcr.io/cirruslabs/macos-tahoe-base:latest", status: "stopped",
                diskGB: 40),
            TartVM(name: "tahoe-base-p3a9f12c4", source: "tahoe-base", status: "stopped", diskGB: 12),
            TartVM(name: "kinhin-1712-abc0def1", source: "tahoe-base", status: "running", diskGB: 50),
        ]
    }

    private func builder(
        config: ConfigScenario,
        tartList: [TartVM]? = nil,
        containerImages: ImageInventory.RuntimeImages? = nil,
        dockerImages: ImageInventory.RuntimeImages? = nil,
        fleet: [VMRecord] = [],
        projectRecords: [ProjectImageRecord] = []
    ) -> DoctorReportBuilder {
        DoctorReportBuilder(
            host: host, clt: .ok(version: "26.6"), tartHealth: .healthy, tartList: tartList,
            config: config, authLoad: { _ in nil }, accountLoad: { _, _ in nil },
            containerHealth: containerImages == nil ? nil : .ready,
            containerImages: containerImages,
            dockerHealth: dockerImages == nil ? nil : .ready,
            dockerImages: dockerImages,
            fleet: fleet,
            projectRecords: projectRecords)
    }

    private func vm(_ id: String, image: String?) -> VMRecord {
        var record = VMRecord(id: id)
        record.image = image
        return record
    }

    private func record(_ name: String) -> ProjectImageRecord {
        ProjectImageRecord(
            name: name, key: name, base: "tahoe-base", summary: "go@1.23",
            createdAt: Date(timeIntervalSince1970: 0), lastUsedAt: Date(timeIntervalSince1970: 1000),
            toolchains: .init(KinhinConfig.ToolchainsConfig()), shareCache: false)
    }

    private func sizedBuilder() -> DoctorReportBuilder {
        builder(
            config: .loaded(Self.linuxConfig),
            tartList: tartImages,
            containerImages: ImageInventory.RuntimeImages(
                names: ["kinhin-ci-linux:latest"], sizesGB: ["kinhin-ci-linux:latest": 4]),
            dockerImages: ImageInventory.RuntimeImages(names: ["ci:latest"], sizesGB: ["ci:latest": 65]))
    }

    // MARK: - JSON contract

    /// One total per runtime, keyed exactly like `image list --json`'s
    /// `totalGB` — and the runner VM's 50 GB is not part of it: runners are
    /// not images.
    func testBreakdownCarriesEveryRuntimeWithSizedListings() async {
        let report = await sizedBuilder().build()
        XCTAssertEqual(
            report.imageTotalGB, ["tart": 52, "container": 4, "docker": 65],
            "tart counts images only (40 + 12; the kinhin-* runner VM is excluded)")
    }

    func testBreakdownIsPartOfTheJSONContract() async throws {
        let report = await sizedBuilder().build()
        let data = try JSONEncoder().encode(report)
        let json = String(decoding: data, as: UTF8.self)
        XCTAssertTrue(json.contains("\"imageTotalGB\""), json)
        let decoded = try JSONDecoder().decode(DoctorReport.self, from: data)
        XCTAssertEqual(decoded.imageTotalGB, report.imageTotalGB, "the breakdown round-trips")
    }

    /// A runtime that reported no sizes has no key (a total would be a
    /// guess), and when nothing was measured the field is absent entirely —
    /// the same contract `image list --json` uses for `totalGB`.
    func testBreakdownOmitsRuntimesWhoseSizesWereNotRead() async {
        let namesOnly = await builder(
            config: .loaded(Self.linuxConfig),
            tartList: [TartVM(name: "tahoe-base", source: "src", status: "stopped")],
            containerImages: ImageInventory.RuntimeImages(names: ["kinhin-ci-linux:latest"]),
            dockerImages: ImageInventory.RuntimeImages(names: ["ci:latest"])
        ).build()
        XCTAssertNil(namesOnly.imageTotalGB, "sizes nobody read → no breakdown, no zeros")

        let partial = await builder(
            config: .loaded(Self.linuxConfig),
            tartList: tartImages,
            containerImages: ImageInventory.RuntimeImages(names: ["kinhin-ci-linux:latest"]),
            dockerImages: ImageInventory.RuntimeImages(names: ["ci:latest"], sizesGB: ["ci:latest": 65])
        ).build()
        XCTAssertEqual(partial.imageTotalGB, ["tart": 52, "docker": 65], "container has no sizes → no key")
    }

    /// Without a parsed config nothing is listed (the checklist's image row
    /// does not run either), so there is nothing to total.
    func testBreakdownIsAbsentWithoutAConfig() async {
        let report = await builder(config: .missing, tartList: tartImages).build()
        XCTAssertNil(report.imageTotalGB)
    }

    // MARK: - Human rendering

    /// The one formatter behind the doctor's `images:` row and the app's
    /// Diagnostics row — both surfaces print exactly this.
    func testImageTotalLineIsTheSharedWording() async {
        let report = await sizedBuilder().build()
        XCTAssertEqual(report.imageTotalLine, "tart 52 GB · container 4 GB · docker 65 GB")
        let unmeasured = await builder(config: .loaded(Self.tartOnlyConfig), tartList: []).build()
        XCTAssertNil(unmeasured.imageTotalLine, "nothing measured → no line")
    }

    func testPlainTextShowsTheBreakdownRow() async {
        let text = await sizedBuilder().buildPlainText()
        XCTAssertTrue(
            text.contains("  images:     tart 52 GB · container 4 GB · docker 65 GB"), text)
    }

    /// A measured-but-sub-GB total reads "<1 GB", never "0 GB" — the same
    /// wording `kinhin image list` uses.
    func testPlainTextNeverSaysZeroGigabytes() async {
        let text = await builder(
            config: .loaded(Self.tartOnlyConfig),
            tartList: [TartVM(name: "tahoe-base", source: "src", status: "stopped", diskGB: 0)]
        ).buildPlainText()
        XCTAssertTrue(text.contains("images:     tart <1 GB"), text)
        XCTAssertFalse(text.contains("tart 0 GB"), text)
    }

    // MARK: - Prune suggestion

    /// Exactly three wastable images — a stray tart VM and two docker
    /// locals. The configured base images, a derived image (index record)
    /// and a stale record are all present in the listings but must not be
    /// counted: the suggestion is `ImagePrunePlan.plan` itself, so it can
    /// never promise a sweep `kinhin image prune` would refuse.
    private func wastefulBuilder() -> DoctorReportBuilder {
        builder(
            config: .loaded(Self.linuxConfig),
            tartList: [
                TartVM(name: "tahoe-base", source: "src", status: "stopped", diskGB: 40),
                TartVM(name: "old-experiment", source: "src", status: "stopped", diskGB: 8),
                TartVM(name: "tahoe-base-p3a9f12c4", source: "tahoe-base", status: "stopped", diskGB: 12),
            ],
            containerImages: ImageInventory.RuntimeImages(
                names: ["kinhin-ci-linux:latest"], sizesGB: ["kinhin-ci-linux:latest": 4]),
            dockerImages: ImageInventory.RuntimeImages(
                names: ["ci:latest", "alpine:3.20", "redis:7"],
                sizesGB: ["ci:latest": 1, "alpine:3.20": 2, "redis:7": 3]),
            projectRecords: [record("tahoe-base-p3a9f12c4"), record("vanished-image")])
    }

    func testPruneSuggestionCountsOnlyWhatTheSweepWouldTake() async {
        let report = await wastefulBuilder().build()
        XCTAssertEqual(report.imagePrune?.count, 3, "stray tart VM + alpine + redis")
        XCTAssertEqual(report.imagePrune?.reclaimGB, 13, "8 + 2 + 3 GB — bases and derived are never swept")
        XCTAssertEqual(report.imagePrune?.command, "kinhin image prune")
        XCTAssertEqual(
            report.imagePruneLine,
            "3 unused image(s) (up to ~13 GB allocated) — review with: kinhin image prune",
            "the shared line wording mirrors the prune report's own count and estimate")
    }

    func testPruneSuggestionIsPartOfTheJSONContract() async throws {
        let report = await wastefulBuilder().build()
        let data = try JSONEncoder().encode(report)
        let json = String(decoding: data, as: UTF8.self)
        XCTAssertTrue(json.contains("\"imagePrune\""), json)
        let decoded = try JSONDecoder().decode(DoctorReport.self, from: data)
        XCTAssertEqual(decoded.imagePrune, report.imagePrune, "the suggestion round-trips")
    }

    func testPlainTextSuggestsPruneUnderTheImagesRow() async {
        let text = await wastefulBuilder().buildPlainText()
        XCTAssertTrue(text.contains("  images:     tart 60 GB · container 4 GB · docker 6 GB"), text)
        XCTAssertTrue(
            text.contains(
                "  prune:      3 unused image(s) (up to ~13 GB allocated) — review with: kinhin image prune"),
            text)
    }

    /// A runner on a local image keeps it out of the count — the suggestion
    /// never offers space that `kinhin image prune` would keep.
    func testPruneSuggestionKeepsInUseImagesOut() async {
        let report = await builder(
            config: .loaded(Self.tartOnlyConfig),
            tartList: [
                TartVM(name: "tahoe-base", source: "src", status: "stopped", diskGB: 40),
                TartVM(name: "busy-local", source: "src", status: "running", diskGB: 9),
                TartVM(name: "idle-local", source: "src", status: "stopped", diskGB: 7),
            ],
            fleet: [vm("kinhin-1712-abc0def1", image: "busy-local")]
        ).build()

        XCTAssertEqual(report.imagePrune?.count, 1, "the image a runner is on is kept, not counted")
        XCTAssertEqual(report.imagePrune?.reclaimGB, 7)
    }

    /// Everything installed is configured: no waste, no advice, no row.
    func testPruneSuggestionIsAbsentWhenNothingIsWasted() async {
        let builder = builder(
            config: .loaded(Self.tartOnlyConfig),
            tartList: [TartVM(name: "tahoe-base", source: "src", status: "stopped", diskGB: 40)])
        let report = await builder.build()
        XCTAssertNil(report.imagePrune)
        XCTAssertNil(report.imagePruneLine)
        let text = await builder.buildPlainText()
        XCTAssertFalse(text.contains("prune:"), text)
    }
}
