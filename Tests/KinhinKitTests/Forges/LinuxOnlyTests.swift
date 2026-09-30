import XCTest

@testable import KinhinKit
@testable import KinhinTestSupport

final class LinuxOnlyTests: XCTestCase {
    private let linux = try! ConfigLoader.parse(
        """
        accounts:
          - name: github
            forge: github
            scope: "acme/widgets"
        labels: [a]
        docker:
          image: "kinhin-ci-linux"
        """)
    private let macOnly = try! ConfigLoader.parse(
        """
        accounts:
          - name: github
            forge: github
            scope: "acme/widgets"
        labels: [a]
        """)

    func testHasLinuxRuntime() {
        XCTAssertTrue(linux.hasLinuxRuntime)
        XCTAssertFalse(macOnly.hasLinuxRuntime)
    }

    func testLinuxOnlyEngineRunsWithoutTart() async throws {
        let engine = FleetEngine(
            config: linux, github: FakeGitHub(), tart: UnavailableTart(),
            store: makeTestStore(), ssh: FakeSSH(), host: testHost)
        await engine.start()
        // The engine starts; nothing throws for the missing tart.
        try await engine.reconcileOnce()
        await engine.stop()
    }

    func testUnavailableTartFailsClearlyAndListsNothing() async {
        let tart = UnavailableTart()
        let vms = try? await tart.list()
        XCTAssertEqual(vms?.count, 0, "recovery finds no tart VMs")
        do { try await tart.clone(source: "a", to: "b"); XCTFail() } catch {
            XCTAssertTrue(error.localizedDescription.contains("tart not found"))
        }
    }

    func testChecklistIsReadyWithoutTartWhenDockerIsConfigured() async {
        let status = await SetupStatusComputer(
            clt: .ok(version: "15"), tartHealth: .missing, config: .loaded(linux),
            accountTokensStored: ["gitea": true], dockerHealth: .ready, dockerImages: ["kinhin-ci-linux"]
        ).compute()
        XCTAssertFalse(status.checks.first { $0.id == "tart" }!.ok, "tart itself is still reported as missing")
        XCTAssertTrue(
            status.ready, "but it no longer blocks a Linux-only fleet: \(status.checks.filter { !$0.ok }.map(\.id))")
    }

    func testChecklistStillNeedsTartForAMacOnlyConfig() async {
        let status = await SetupStatusComputer(
            clt: .ok(version: "15"), tartHealth: .missing, config: .loaded(macOnly),
            accountTokensStored: ["gitea": true]
        ).compute()
        XCTAssertFalse(status.ready)
    }
}
