import XCTest

@testable import KinhinKit
@testable import KinhinTestSupport

/// Covers the runner-permission verification (PAT can manage runners for the
/// scope) and the engine's start gate that blocks a doomed fleet before it
/// spawns anything.
final class OrgPermissionTests: XCTestCase {
    // MARK: Probe

    func testVerifyPassesWhenTokenMintSucceeds() async {
        let report = await OrgPermissionProbe.verify(github: FakeGitHub(), scope: "acme")
        XCTAssertTrue(report.ok)
        XCTAssertTrue(report.message.contains("organization 'acme'"), report.message)
    }

    func testVerifyReportsRepoKindForRepoScope() async {
        let report = await OrgPermissionProbe.verify(github: FakeGitHub(), scope: "acme/widgets")
        XCTAssertTrue(report.ok)
        XCTAssertTrue(report.message.contains("repository 'acme/widgets'"), report.message)
    }

    func testForbiddenForbiddenMapsToPermissionHint() async {
        let github = FakeGitHub()
        github.permissionDenied = true
        let report = await OrgPermissionProbe.verify(github: github, scope: "acme")
        XCTAssertFalse(report.ok)
        XCTAssertTrue(report.message.contains("lacks runner-management permission"), report.message)
        XCTAssertTrue(report.message.contains("admin:org"), "org remediation must mention the scope: \(report.message)")
    }

    func testRepoScopeForbiddenMentionsRepoRemediation() async {
        let github = FakeGitHub()
        github.permissionDenied = true
        let report = await OrgPermissionProbe.verify(github: github, scope: "acme/widgets")
        XCTAssertFalse(report.ok)
        XCTAssertTrue(report.message.contains("Administration: Read and write"), report.message)
        XCTAssertFalse(report.message.contains("admin:org"), "repo hint must not leak org advice")
    }

    func testUnauthorizedMapsToAuthFix() async {
        let github = FakeGitHub()
        github.unauthorized = true
        let report = await OrgPermissionProbe.verify(github: github, scope: "acme")
        XCTAssertFalse(report.ok)
        XCTAssertTrue(report.message.contains("kinhin auth set"), report.message)
    }

    func testOrgScopeNotFoundMapsToRunnerRemediation() async {
        let github = FakeGitHub()
        github.notFound = true
        let report = await OrgPermissionProbe.verify(github: github, scope: "acme")
        XCTAssertFalse(report.ok)
        XCTAssertTrue(report.message.contains("lacks runner-management permission"))
        XCTAssertTrue(report.message.contains("admin:org"), "org remediation must mention the scope: \(report.message)")
        XCTAssertTrue(
            report.message.contains("Self-hosted runners: Read and write"), "fine-grained remediation must be present")
    }

    func testRepoScopeNotFoundMapsToRepoMessage() async {
        let github = FakeGitHub()
        github.notFound = true
        let report = await OrgPermissionProbe.verify(github: github, scope: "acme/widgets")
        XCTAssertFalse(report.ok)
        XCTAssertTrue(report.message.contains("can't reach"))
        XCTAssertFalse(report.message.contains("lacks runner-management"), "repo scope 404s should not leak org advice")
    }

    // MARK: Engine start gate

    func makeEngine(github: FakeGitHub, tart: FakeTart = FakeTart()) -> FleetEngine {
        FleetEngine(
            config: makeTestConfig(),
            github: github,
            tart: tart,
            store: makeTestStore(),
            ssh: FakeSSH(),
            host: testHost
        )
    }

    func testStartGateBlocksWithoutPermission() async throws {
        let github = FakeGitHub()
        let tart = FakeTart()
        github.permissionDenied = true
        github.queueDepth = 3
        let engine = makeEngine(github: github, tart: tart)

        await engine.start()
        try await Task.sleep(nanoseconds: 500_000_000)

        let status = await engine.status()
        XCTAssertFalse(status.running, "engine must not run without permission")
        XCTAssertTrue(status.lastError?.contains("lacks runner-management") ?? false, status.lastError ?? "no error")
        XCTAssertTrue(tart.cloneCalls.isEmpty, "no VMs may be spawned")
        XCTAssertTrue(status.records.isEmpty)
        await engine.stop()
    }

    func testStartGatePassesAndFleetRuns() async throws {
        let github = FakeGitHub()
        github.queueDepth = 1
        let engine = makeEngine(github: github)

        await engine.start()
        try await Task.sleep(nanoseconds: 500_000_000)

        let status = await engine.status()
        XCTAssertTrue(status.running)
        XCTAssertNil(status.lastError)
        await engine.stop()
    }
}
