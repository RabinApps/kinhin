import XCTest

@testable import KinhinKit

/// `kinhin doctor` lists the configured storage paths with their preflight, and a failed one makes the report not
/// ready.
final class DoctorStorageSectionTests: XCTestCase {
    private func config(_ storage: KinhinConfig.StorageConfig) -> KinhinConfig {
        var cfg = KinhinConfig.default
        cfg.storage = storage
        return cfg
    }

    func testNoConfiguredPathMeansNoSection() {
        XCTAssertNil(DoctorReportBuilder.storageSection(config: config(.init()), preflight: .live))
        XCTAssertNil(DoctorReportBuilder.storageSection(config: nil, preflight: .live))
    }

    func testEachPathIsReportedWithItsVolumeAndProblem() throws {
        let preflight = StoragePreflight(
            volume: { path in
                StoragePreflight.Volume(
                    mountPoint: path.hasPrefix("/Volumes/Storage") ? "/Volumes/Storage" : "/", ignoresOwnership: false)
            },
            entry: { _ in .directory })
        let section = try XCTUnwrap(
            DoctorReportBuilder.storageSection(
                config: config(.init(tartHome: "/Volumes/Storage/tart", containerAppRoot: "/Volumes/Gone/container")),
                preflight: preflight))
        XCTAssertFalse(section.ok)
        XCTAssertEqual(section.paths.map(\.key), ["tart_home", "container_app_root"])
        XCTAssertEqual(section.paths[0].mountPoint, "/Volumes/Storage")
        XCTAssertTrue(section.paths[0].ok)
        XCTAssertNil(section.paths[0].problem)
        XCTAssertEqual(section.paths[1].problem, "the volume /Volumes/Gone is not mounted")
        XCTAssertNotNil(section.paths[1].fix)
    }

    func testTheSectionRoundTripsThroughJSON() throws {
        let section = DoctorReport.StorageSection(paths: [
            .init(key: "tart_home", path: "/Volumes/S/tart", mountPoint: "/Volumes/S", ok: true, problem: nil, fix: nil)
        ])
        let data = try JSONEncoder().encode(section)
        XCTAssertEqual(try JSONDecoder().decode(DoctorReport.StorageSection.self, from: data), section)
    }
}
