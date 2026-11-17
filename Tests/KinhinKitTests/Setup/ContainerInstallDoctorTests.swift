import XCTest

@testable import KinhinKit
@testable import KinhinTestSupport

/// `kinhin doctor` reports where Apple's `container` came from and warns when an ad-hoc build keeps its data on an
/// external volume, without making the report not ready (#106).
final class ContainerInstallDoctorTests: XCTestCase {
    private let host = HostResources(logicalCores: 10, memoryGB: 32, freeDiskGB: 200, arm64: true)
    private let brewExternal = AppleContainerInstall(
        binaryPath: "/opt/homebrew/Cellar/container/1.6.1/libexec/container", source: .homebrew, signature: .adhoc,
        teamID: nil, appRoot: "/Volumes/Fast/container", appRootExternal: true)

    private func config() -> KinhinConfig {
        var cfg = makeTestConfig()
        cfg.container = .init(image: "kinhin-ci-linux")
        return cfg
    }

    private func report(install: AppleContainerInstall?) async -> DoctorReport {
        await DoctorReportBuilder(
            host: host, clt: .ok(version: "27.0"), tartHealth: .healthy, tartList: [], config: .loaded(config()),
            authLoad: { _ in "token" }, accountLoad: { _, _ in "token" }, containerHealth: .ready,
            containerImages: .init(names: ["kinhin-ci-linux:latest"]), dockerInstalled: false,
            softnetInstalled: false, fleet: [], projectRecords: [], containerInstall: install
        ).build()
    }

    func testTheReportCarriesTheInstallAndWarnsInText() async throws {
        let built = await report(install: brewExternal)
        XCTAssertEqual(built.container?.install, brewExternal)
        XCTAssertTrue(built.plainText.contains("cont from:"), built.plainText)
        XCTAssertTrue(built.plainText.contains("Homebrew, ad-hoc signed, data on external volume"), built.plainText)
        XCTAssertTrue(built.plainText.contains("⚠ container is ad-hoc signed"), built.plainText)
    }

    func testTheWarningDoesNotMakeTheContainerSectionFail() async throws {
        let built = await report(install: brewExternal)
        XCTAssertEqual(built.container?.ok, true)
    }

    func testWithInjectedHealthTheBuilderNeverRunsCodesign() async {
        let built = await report(install: nil)
        XCTAssertNil(built.container?.install, "no fixture and no live probe in a test")
        XCTAssertFalse(built.plainText.contains("cont from"))
    }

    func testTheJSONCarriesTheInstallAndOldReportsStillDecode() throws {
        let section = try XCTUnwrap(
            DoctorReportBuilder.containerSection(
                config: config(), health: .ready, images: .init(names: ["kinhin-ci-linux:latest"]), host: host,
                install: brewExternal))
        let object = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: JSONEncoder().encode(section)) as? [String: Any])
        let install = try XCTUnwrap(object["install"] as? [String: Any])
        XCTAssertEqual(install["source"] as? String, "homebrew")
        XCTAssertEqual(install["signature"] as? String, "adhoc")
        XCTAssertEqual(install["appRootExternal"] as? Bool, true)

        let old = #"{"state":"ready","ok":true,"image":"kinhin-ci-linux","imageFound":true}"#
        XCTAssertNil(try JSONDecoder().decode(DoctorReport.ContainerSection.self, from: Data(old.utf8)).install)
    }
}
