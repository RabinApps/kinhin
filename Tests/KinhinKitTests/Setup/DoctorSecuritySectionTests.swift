import Synchronization
import XCTest

@testable import KinhinKit

/// The isolation/transport posture `kinhin doctor` reports.
final class DoctorSecuritySectionTests: XCTestCase {
    private let host = HostResources(logicalCores: 10, memoryGB: 32, freeDiskGB: 200, arm64: true)

    private func config(
        softnet: Bool? = nil, shareCache: Bool? = nil, accounts: [AccountConfig] = []
    ) -> KinhinConfig {
        var cfg = KinhinConfig.default
        cfg.accounts = [AccountConfig(name: "github", forge: .github, scope: "acme/widgets")] + accounts
        cfg.tartSoftnet = softnet
        if let shareCache {
            cfg.projects = [
                KinhinConfig.ProjectConfig(
                    pattern: "acme/widgets", toolchains: KinhinConfig.ToolchainsConfig(specs: ["node@22"]),
                    shareCache: shareCache)
            ]
        }
        return cfg
    }

    private func report(_ cfg: KinhinConfig, softnetInstalled: Bool = true) async -> DoctorReport {
        await DoctorReportBuilder(
            host: host, clt: .ok(version: "26.6"), tartHealth: .healthy, tartList: [],
            config: .loaded(cfg), authLoad: { _ in "tok" }, accountLoad: { _, _ in "tok" },
            softnetInstalled: softnetInstalled,
            hostKeyMarker: FileManager.default.temporaryDirectory.appendingPathComponent("kinhin-no-marker-\(UUID())")
        ).build()
    }

    /// The checklist and the auth half share one Keychain read per account
    /// token, and the doctor probes the Linux runtimes once (the section
    /// reuses the checklist's answers).
    func testDoctorReadsEachAccountTokenOnceAndProbesEachRuntimeOnce() async {
        let reads = Mutex<[String: Int]>([:])
        var cfg = config()
        cfg.docker = KinhinConfig.DockerForgeConfig(image: "kinhin-ci-linux")
        let report = await DoctorReportBuilder(
            host: host, clt: .ok(version: "26.6"), tartHealth: .healthy, tartList: [],
            config: .loaded(cfg), authLoad: { _ in "tok" },
            accountLoad: { forge, name in
                reads.withLock { $0["\(forge.rawValue):\(name)", default: 0] += 1 }
                return "tok"
            },
            dockerHealth: .ready, dockerImages: ["kinhin-ci-linux:latest"], softnetInstalled: true
        ).build()
        XCTAssertFalse(reads.withLock { $0 }.isEmpty, "the accounts were read")
        XCTAssertTrue(reads.withLock { $0 }.values.allSatisfy { $0 == 1 }, "\(reads.withLock { $0 })")
        XCTAssertEqual(report.docker?.state, "ready")
        XCTAssertEqual(report.docker?.imageFound, true)
        XCTAssertEqual(report.checks.first { $0.id == "docker-image" }?.ok, true)
    }

    func testDefaultConfigAdvisesAboutTheSharedNetwork() throws {
        let section = try XCTUnwrap(DoctorReportBuilder.securitySection(config: config(), softnetInstalled: false))
        XCTAssertFalse(section.softnetEnabled)
        XCTAssertTrue(section.ok, "an advisory never blocks readiness")
        XCTAssertNil(section.fix)
        XCTAssertEqual(section.warnings.count, 1)
        XCTAssertTrue(section.warnings[0].contains("tart_softnet: true"))
    }

    func testNoNetworkAdvisoryWhenTartIsNotInUse() throws {
        let section = try XCTUnwrap(
            DoctorReportBuilder.securitySection(config: config(), softnetInstalled: false, tartHealthy: false))
        XCTAssertTrue(section.warnings.isEmpty)
    }

    func testSoftnetOnAndInstalledIsQuiet() throws {
        let section = try XCTUnwrap(
            DoctorReportBuilder.securitySection(config: config(softnet: true), softnetInstalled: true))
        XCTAssertTrue(section.softnetEnabled)
        XCTAssertTrue(section.softnetInstalled)
        XCTAssertTrue(section.ok)
        XCTAssertTrue(section.warnings.isEmpty)
    }

    func testSoftnetOnButMissingIsAFailureWithTheInstallCommand() throws {
        let section = try XCTUnwrap(
            DoctorReportBuilder.securitySection(config: config(softnet: true), softnetInstalled: false))
        XCTAssertFalse(section.ok)
        XCTAssertTrue(try XCTUnwrap(section.fix).contains("brew install openai/tools/softnet"))
    }

    func testInsecureHTTPAccountsAndSharedCacheAreListed() throws {
        let lan = AccountConfig(
            name: "lab", forge: .gitea, scope: "me/repo", instance: "http://gitea.lan:3000", allowInsecureHTTP: true)
        let local = AccountConfig(name: "dev", forge: .gitea, scope: "me/r2", instance: "http://localhost:3000")
        let secure = AccountConfig(name: "ok", forge: .gitlab, scope: "g/p", instance: "https://gitlab.example.com")
        let section = try XCTUnwrap(
            DoctorReportBuilder.securitySection(
                config: config(softnet: true, shareCache: true, accounts: [lan, local, secure]), softnetInstalled: true)
        )
        XCTAssertEqual(section.insecureHTTPAccounts, ["lab"], "loopback and https accounts are not flagged")
        XCTAssertTrue(section.sharedCacheWritable)
        XCTAssertEqual(section.warnings.count, 2)
        XCTAssertTrue(section.warnings.contains { $0.contains("'lab'") && $0.contains("plain http") })
        XCTAssertTrue(section.warnings.contains { $0.contains("share_cache") })
    }

    func testNoSectionWhenTheConfigDidNotParse() {
        XCTAssertNil(DoctorReportBuilder.securitySection(config: nil))
    }

    // MARK: - Whole report

    func testReportCarriesTheSectionAndAFailureBlocksReadiness() async throws {
        let healthy = await report(config(softnet: true), softnetInstalled: true)
        XCTAssertEqual(try XCTUnwrap(healthy.security).ok, true)

        let broken = await report(config(softnet: true), softnetInstalled: false)
        XCTAssertFalse(try XCTUnwrap(broken.security).ok)
        XCTAssertFalse(broken.ready, "the fleet would refuse to start")

        let advisoryOnly = await report(config(), softnetInstalled: false)
        XCTAssertEqual(advisoryOnly.ready, healthy.ready, "advisories do not change readiness")
    }

    func testPlainTextShowsSoftnetStateAndAdvisories() async {
        let off = await report(config(shareCache: true)).plainText
        XCTAssertTrue(off.contains("softnet:"), off)
        XCTAssertTrue(off.contains("off (runner VMs share one network)"), off)
        XCTAssertTrue(off.contains("a project has share_cache on"), off)

        let on = await report(config(softnet: true)).plainText
        XCTAssertTrue(on.contains("on ✓ (runner VMs are isolated"), on)
        XCTAssertTrue(on.contains("no advisories ✓"), on)

        let missing = await report(config(softnet: true), softnetInstalled: false).plainText
        XCTAssertTrue(missing.contains("NOT INSTALLED"), missing)
    }

    func testSectionRoundTripsThroughJSON() async throws {
        let original = await report(config(softnet: true, shareCache: true))
        let decoded = try JSONDecoder().decode(DoctorReport.self, from: JSONEncoder().encode(original))
        XCTAssertEqual(decoded.security, original.security)
    }
}
