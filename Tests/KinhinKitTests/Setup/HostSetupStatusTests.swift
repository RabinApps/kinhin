import XCTest

@testable import KinhinKit

/// The host-runtime checklist row and doctor section: they appear only when
/// a route targets `host`, carry the unisolated disclosure, and offer the
/// agent-install fix when the agent is missing.
final class HostSetupStatusTests: XCTestCase {
    private let hostResources = HostResources(logicalCores: 10, memoryGB: 64, freeDiskGB: 120, arm64: true)

    private func config(hostRoute: Bool) -> KinhinConfig {
        var cfg = KinhinConfig.default
        cfg.accounts = [AccountConfig(name: "github", forge: .github, scope: "acme/widgets")]
        if hostRoute {
            var rc = KinhinConfig.RuntimeConfig()
            rc.routes = [.init(pattern: "acme/scripts", runtime: RuntimeID.host.rawValue, consent: true)]
            cfg.runtimes = rc
        }
        return cfg
    }

    private func status(hostRoute: Bool, health: RuntimeHealth) async -> SetupStatus {
        await SetupStatusComputer(
            host: hostResources, clt: .ok(version: "27.0"), tartHealth: .healthy,
            tartList: [
                TartVM(
                    name: "tahoe-base", source: "ghcr.io/cirruslabs/macos-tahoe-base:latest", status: "suspended",
                    cpu: nil, memoryMB: nil)
            ],
            config: .loaded(config(hostRoute: hostRoute)), accountTokensStored: ["github": true], hostHealth: health
        ).compute()
    }

    func testNoHostRowWithoutHostRoutes() async {
        let result = await status(hostRoute: false, health: .missing(tool: "agent", fix: "x"))
        XCTAssertNil(result.checks.first { $0.id == "host-agent" })
        XCTAssertTrue(result.ready)
    }

    func testMissingAgentOffersInstallAndBlocksReadiness() async throws {
        let result = await status(hostRoute: true, health: .missing(tool: "agent", fix: "x"))
        let row = try XCTUnwrap(result.checks.first { $0.id == "host-agent" })
        XCTAssertFalse(row.ok)
        XCTAssertEqual(row.action, "install_host_agent")
        XCTAssertEqual(SetupAction.title(for: "install_host_agent"), "Install Host Runner Agent")
        XCTAssertFalse(result.ready)
    }

    func testReadyAgentDisclosesNoIsolation() async throws {
        let result = await status(hostRoute: true, health: .ready)
        let row = try XCTUnwrap(result.checks.first { $0.id == "host-agent" })
        XCTAssertTrue(row.ok)
        XCTAssertTrue(row.detail.contains("unisolated"), row.detail)
        XCTAssertNil(row.action)
    }

    func testDoctorHostSectionListsRoutesAndFix() async throws {
        let report = await DoctorReportBuilder(
            host: hostResources, clt: .ok(version: "27.0"), tartHealth: .healthy, tartList: [],
            config: .loaded(config(hostRoute: true)), authLoad: { _ in "token" },
            hostHealth: .missing(tool: "agent", fix: "x")
        ).build()
        let section = try XCTUnwrap(report.hostRuntime)
        XCTAssertEqual(section.state, "missing")
        XCTAssertEqual(section.routes, ["acme/scripts"])
        XCTAssertEqual(section.fix, "kinhin setup repair host-agent")
        XCTAssertTrue(section.warning.contains("unisolated"))
    }

    func testDoctorOmitsHostSectionWithoutRoutes() async {
        let report = await DoctorReportBuilder(
            host: hostResources, clt: .ok(version: "27.0"), tartHealth: .healthy, tartList: [],
            config: .loaded(config(hostRoute: false)), authLoad: { _ in "token" }, hostHealth: .ready
        ).build()
        XCTAssertNil(report.hostRuntime)
    }
}
