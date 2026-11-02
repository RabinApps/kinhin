import XCTest

@testable import KinhinKit

/// `kinhin doctor`, the checklist's image row and `kinhin status` with named container pools (#75, step 2): every
/// pool's image must be local, each pool is listed with its shape, a pool that can never fit is flagged, and an
/// instance shows its pool.
final class ContainerPoolsDoctorTests: XCTestCase {
    private let host = HostResources(logicalCores: 10, memoryGB: 32, freeDiskGB: 200, arm64: true)

    private func config(bigCPUs: Int = 4) -> KinhinConfig {
        var cfg = KinhinConfig.default
        cfg.container = .init(
            image: "kinhin-ci-linux",
            pools: [
                .init(name: "big", image: "kinhin-ci-big", cpus: bigCPUs, memoryGB: 12, labels: ["big"], max: 2),
                .init(name: "linux", image: "kinhin-ci-linux", cpus: 2, memoryGB: 7, docker: true),
            ])
        return cfg
    }

    private func section(
        _ cfg: KinhinConfig, images: [String], health: RuntimeHealth = .ready
    ) -> DoctorReport.ContainerSection? {
        DoctorReportBuilder.containerSection(
            config: cfg, health: health, images: .init(names: images), host: host)
    }

    func testEveryPoolsImageMustBeLocal() throws {
        let missing = try XCTUnwrap(section(config(), images: ["kinhin-ci-linux:latest"]))
        XCTAssertFalse(missing.imageFound)
        XCTAssertEqual(missing.image, "kinhin-ci-big", "the image to build next")
        XCTAssertEqual(missing.fix, "kinhin image prepare --container --pool big")
        XCTAssertEqual(missing.pools?.map(\.imageFound), [false, true])

        let none = try XCTUnwrap(section(config(), images: []))
        XCTAssertEqual(none.fix, "kinhin image prepare --container --all", "two images to build: all of them")

        let built = try XCTUnwrap(section(config(), images: ["kinhin-ci-linux", "kinhin-ci-big"]))
        XCTAssertTrue(built.imageFound)
        XCTAssertNil(built.fix)
        XCTAssertEqual(built.image, "kinhin-ci-linux", "the default pool's image when everything is built")
    }

    func testEachPoolIsListedWithItsShapeAndWhetherItFits() throws {
        let fits = try XCTUnwrap(section(config(), images: ["kinhin-ci-linux", "kinhin-ci-big"])?.pools)
        XCTAssertEqual(fits.map(\.name), ["big", "linux"])
        XCTAssertEqual(fits.map(\.fits), [true, true])
        XCTAssertEqual(fits[0].max, 2)
        XCTAssertTrue(fits[1].docker)

        // 10 cores minus the default reserve of 2 leave 8 CPU: 12 never fit.
        let huge = try XCTUnwrap(section(config(bigCPUs: 12), images: ["kinhin-ci-linux", "kinhin-ci-big"])?.pools)
        XCTAssertEqual(huge.map(\.fits), [false, true])
        let line = DoctorReport.containerPoolLine(huge[0], runtimeReady: true)
        XCTAssertTrue(line.hasPrefix("big (12 CPU, 12 GB, max 2): kinhin-ci-big ✓"), line)
        XCTAssertTrue(line.contains("never fits the Apple container budget (8 CPU, 28 GB)"), line)
    }

    func testAPoolLineSaysHowToPrepareAMissingImage() throws {
        let pools = try XCTUnwrap(section(config(), images: ["kinhin-ci-linux"])?.pools)
        XCTAssertEqual(
            DoctorReport.containerPoolLine(pools[0], runtimeReady: true),
            "big (4 CPU, 12 GB, max 2): kinhin-ci-big NOT LOCAL — prepare with: kinhin image prepare --container --pool big"
        )
        XCTAssertEqual(
            DoctorReport.containerPoolLine(pools[1], runtimeReady: true),
            "linux (2 CPU, 7 GB, docker): kinhin-ci-linux ✓")
    }

    func testASectionWithoutPoolsReportsAsBefore() throws {
        var cfg = config()
        cfg.container?.pools = []
        let found = try XCTUnwrap(section(cfg, images: ["kinhin-ci-linux:1.2"]))
        XCTAssertNil(found.pools)
        XCTAssertTrue(found.imageFound)
        let absent = try XCTUnwrap(section(cfg, images: []))
        XCTAssertEqual(absent.fix, "kinhin image prepare --container --target kinhin-ci-linux")
        XCTAssertEqual(absent.image, "kinhin-ci-linux")
    }

    func testStatusShowsEachInstancesPool() {
        var record = VMRecord(id: "kinhin-1700000000-0000abcd", phase: .ready)
        record.runtimeID = .appleContainer
        record.pool = "big"
        let text = FleetStatusFormatter.report(FleetStatus(records: [record]))
        XCTAssertTrue(text.contains("kinhin-1700000000-0000abcd  ready  pool=big  up="), text)
    }
}
