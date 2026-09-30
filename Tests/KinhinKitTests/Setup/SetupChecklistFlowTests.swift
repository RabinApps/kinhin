import XCTest

@testable import KinhinKit

/// The setup window's checklist flow, end to end: how SetupStatusComputer
/// computes each check, how the rows order and gate readiness, and how every
/// check state maps to the repair action the window's buttons dispatch on.
///
/// Complements the sibling suites: SetupStatusTests pins the base six-row
/// contract, ActionCoverageTests pins handler coverage across the scenario
/// matrix, and ContainerSetupStatusTests pins the container rows. This file
/// covers what those leave open: combined Gitea+container ordering, the full
/// CLT state table, and readiness biconditionals.
final class SetupChecklistFlowTests: XCTestCase {
    // MARK: Fixtures

    private func host(arm64: Bool = true) -> HostResources {
        HostResources(logicalCores: 10, memoryGB: 64, freeDiskGB: 120, arm64: arm64)
    }

    private func vm(name: String) -> TartVM {
        TartVM(
            name: name, source: "ghcr.io/cirruslabs/macos-tahoe-base:latest", status: "suspended", cpu: nil,
            memoryMB: nil)
    }

    private func config(
        repo: String = "acme/widgets",
        gitea: Bool = false,
        container: Bool = false
    ) -> KinhinConfig {
        var cfg = KinhinConfig.default
        cfg.accounts = [AccountConfig(name: "github", forge: .github, scope: repo)]
        cfg.image = "tahoe-base"
        if gitea {
            cfg.accounts.append(
                AccountConfig(
                    name: "gitea", forge: .gitea, scope: "acme", instance: "https://gitea.example.com",
                    labels: ["macos:host"]))
        }
        if container {
            cfg.container = KinhinConfig.ContainerConfig(image: "kinhin-ci-linux")
        }
        return cfg
    }

    /// The everything-green base state tests branch from.
    private func readyComputer(
        gitea: Bool = false,
        container: Bool = false,
        githubTokenStored: Bool = true,
        giteaTokenStored: Bool = true
    ) -> SetupStatusComputer {
        SetupStatusComputer(
            host: host(),
            clt: .ok(version: "27.0"),
            tartHealth: .healthy,
            tartList: [vm(name: "tahoe-base")],
            config: .loaded(config(gitea: gitea, container: container)),
            accountTokensStored: ["github": githubTokenStored, "gitea": giteaTokenStored]
                .filter { gitea ? $0.key == "github" || $0.key == "gitea" : $0.key == "github" },
            containerHealth: container ? .ready : nil,
            containerImages: container ? ["kinhin-ci-linux"] : nil
        )
    }

    // MARK: Check computation — CLT state → row + action

    func testCLTStatesMapToOkFlagAndFixAction() async {
        let states: [(String, CLTState, Bool, String?)] = [
            ("ok", .ok(version: "27.0"), true, nil),
            ("outdated", .outdated(version: "26.6", macOSVersion: "27.0"), false, "fix_clt"),
            ("missing", .missing, false, "fix_clt"),
            ("unselected", .unselected, false, "fix_clt"),
        ]
        for (name, state, expectedOK, expectedAction) in states {
            let computer = SetupStatusComputer(
                host: host(),
                clt: state,
                tartHealth: .missing,
                tartList: [],
                config: .missing,
                accountTokensStored: ["github": false]
            )
            let status = await computer.compute()
            let row = status.checks.first { $0.id == "clt" }
            XCTAssertEqual(row?.ok, expectedOK, "[\(name)] clt ok flag")
            XCTAssertEqual(row?.action, expectedAction, "[\(name)] clt action")
            // Every non-ok CLT state carries the reinstall hint in its detail.
            if !expectedOK {
                XCTAssertEqual(row?.detail, state.detail, "[\(name)] detail must come from the probe")
            }
        }
    }

    func testCLTOkDetailCarriesVersion() async {
        let computer = SetupStatusComputer(
            host: host(),
            clt: .ok(version: "26.9"),
            tartHealth: .healthy,
            tartList: [vm(name: "tahoe-base")],
            config: .loaded(config()),
            accountTokensStored: ["github": true]
        )
        let status = await computer.compute()
        let row = status.checks.first { $0.id == "clt" }
        XCTAssertTrue(row?.detail.contains("26.9") ?? false)
    }

    // MARK: Check computation — Gitea row appears only when configured

    func testGiteaRowAbsentWhenForgeNotConfigured() async {
        let status = await readyComputer().compute()
        XCTAssertNil(status.checks.first { $0.id == "account-token-gitea" })
    }

    func testGiteaTokenStatesMapToEnterAndReplaceActions() async {
        let missing = await readyComputer(gitea: true, giteaTokenStored: false).compute()
        let giteaMissing = missing.checks.first { $0.id == "account-token-gitea" }
        XCTAssertEqual(giteaMissing?.ok, false)
        XCTAssertEqual(giteaMissing?.action, "enter_account_token")
        XCTAssertFalse(missing.ready, "a missing Gitea token must block readiness when the forge is configured")

        let stored = await readyComputer(gitea: true, giteaTokenStored: true).compute()
        let giteaStored = stored.checks.first { $0.id == "account-token-gitea" }
        XCTAssertEqual(giteaStored?.ok, true)
        XCTAssertEqual(giteaStored?.action, "replace_account_token", "stored tokens stay replaceable")
        XCTAssertTrue(stored.ready, "a stored Gitea token satisfies the row")
    }

    // MARK: Ordering — optional rows keep a deterministic position

    func testGiteaRowSitsBetweenTokenAndImage() async {
        let status = await readyComputer(gitea: true).compute()
        XCTAssertEqual(
            status.checks.map(\.id),
            [
                "arch", "clt", "tart", "config", "account-token-github", "account-token-gitea", "image",
                "toolchain-cache",
            ])
    }

    func testGiteaAndContainerRowsOrderTogether() async {
        let status = await readyComputer(gitea: true, container: true).compute()
        XCTAssertEqual(
            status.checks.map(\.id),
            [
                "arch", "clt", "tart", "config", "account-token-github", "account-token-gitea", "image",
                "container-cli", "container-image", "toolchain-cache",
            ])
        XCTAssertTrue(status.ready)
    }

    func testRollbackReplacesTartRowPosition() async {
        // The killed-on-launch row takes the tart slot — the checklist stays
        // fixed-length and in order, never grows a ninth row.
        let computer = SetupStatusComputer(
            host: host(),
            clt: .ok(version: "27.0"),
            tartHealth: .killedOnLaunch,
            tartList: [],
            config: .loaded(config()),
            accountTokensStored: ["github": true]
        )
        let status = await computer.compute()
        XCTAssertEqual(
            status.checks.map(\.id),
            ["arch", "clt", "tart-rollback", "config", "account-token-github", "image", "toolchain-cache"])
    }

    // MARK: Readiness — ready is exactly "every check ok"

    func testReadinessMirrorsEveryCheckSatisfied() async {
        // Probe the biconditional both ways: any single red row blocks ready,
        // and only the all-green checklist earns it.
        let blockers: [(String, SetupStatusComputer)] = [
            (
                "arch",
                SetupStatusComputer(
                    host: host(arm64: false), clt: .ok(version: "27.0"), tartHealth: .healthy,
                    tartList: [vm(name: "tahoe-base")], config: .loaded(config()), accountTokensStored: ["github": true]
                )
            ),
            (
                "clt",
                SetupStatusComputer(
                    host: host(), clt: .missing, tartHealth: .healthy, tartList: [vm(name: "tahoe-base")],
                    config: .loaded(config()), accountTokensStored: ["github": true])
            ),
            (
                "tart",
                SetupStatusComputer(
                    host: host(), clt: .ok(version: "27.0"), tartHealth: .broken("crash"), tartList: [],
                    config: .loaded(config()), accountTokensStored: ["github": true])
            ),
            (
                "config",
                SetupStatusComputer(
                    host: host(), clt: .ok(version: "27.0"), tartHealth: .healthy, tartList: [vm(name: "tahoe-base")],
                    config: .missing, accountTokensStored: ["github": true])
            ),
            (
                "account-token-github",
                SetupStatusComputer(
                    host: host(), clt: .ok(version: "27.0"), tartHealth: .healthy, tartList: [vm(name: "tahoe-base")],
                    config: .loaded(config()), accountTokensStored: ["github": false])
            ),
            (
                "image",
                SetupStatusComputer(
                    host: host(), clt: .ok(version: "27.0"), tartHealth: .healthy, tartList: [vm(name: "unrelated")],
                    config: .loaded(config()), accountTokensStored: ["github": true])
            ),
        ]
        for (blockedBy, computer) in blockers {
            let status = await computer.compute()
            XCTAssertFalse(status.ready, "[\(blockedBy)] must block readiness")
            let failedRow = status.checks.first { !$0.ok }
            XCTAssertEqual(failedRow?.id, blockedBy, "[\(blockedBy)] the failing row should be the blocker itself")
        }

        let green = await readyComputer().compute()
        XCTAssertTrue(green.ready)
        XCTAssertTrue(green.checks.allSatisfy(\.ok))
    }

    // MARK: Check state → repair action, full table

    func testEveryFailingRowOffersExactlyOneRepairAction() async {
        // The window shows at most one fix button per row; each failing row
        // must offer exactly one, each passing row none.
        let states: [(String, SetupStatusComputer)] = [
            (
                "fresh",
                SetupStatusComputer(
                    host: host(), clt: .missing, tartHealth: .missing, tartList: [], config: .missing,
                    accountTokensStored: ["github": false])
            ),
            (
                "killed",
                SetupStatusComputer(
                    host: host(), clt: .outdated(version: "26.6", macOSVersion: "27.0"), tartHealth: .killedOnLaunch,
                    tartList: [], config: .template, accountTokensStored: ["github": false])
            ),
            (
                "mixed forges",
                SetupStatusComputer(
                    host: host(), clt: .ok(version: "27.0"), tartHealth: .healthy, tartList: [vm(name: "tahoe-base")],
                    config: .loaded(config(gitea: true, container: true)),
                    accountTokensStored: ["github": false, "gitea": false],
                    containerHealth: .broken("service down"), containerImages: [])
            ),
        ]
        for (name, computer) in states {
            let status = await computer.compute()
            for check in status.checks {
                if check.ok {
                    XCTAssertNil(check.action, "[\(name)] row '\(check.id)' is ok but still offers an action")
                } else {
                    XCTAssertNotNil(check.action, "[\(name)] failing row '\(check.id)' must offer a repair")
                }
            }
        }
    }

    func testEachCheckFailureMapsToItsDistinctAction() async {
        // One representative failure per check id, pinned action-for-action.
        // (Token rows always carry an action — enter vs replace — covered above.)
        let cases: [(id: String, action: String, computer: SetupStatusComputer)] = [
            (
                "clt", "fix_clt",
                SetupStatusComputer(
                    host: host(), clt: .missing, tartHealth: .healthy, tartList: [vm(name: "tahoe-base")],
                    config: .loaded(config()), accountTokensStored: ["github": true])
            ),
            (
                "tart", "install_tart",
                SetupStatusComputer(
                    host: host(), clt: .ok(version: "27.0"), tartHealth: .missing, tartList: [],
                    config: .loaded(config()), accountTokensStored: ["github": true])
            ),
            (
                "tart-rollback", "rollback_tart",
                SetupStatusComputer(
                    host: host(), clt: .ok(version: "27.0"), tartHealth: .killedOnLaunch, tartList: [],
                    config: .loaded(config()), accountTokensStored: ["github": true])
            ),
            (
                "tart", "reinstall_tart",
                SetupStatusComputer(
                    host: host(), clt: .ok(version: "27.0"), tartHealth: .broken("crash"), tartList: [],
                    config: .loaded(config()), accountTokensStored: ["github": true])
            ),
            (
                "config", "create_config",
                SetupStatusComputer(
                    host: host(), clt: .ok(version: "27.0"), tartHealth: .healthy, tartList: [vm(name: "tahoe-base")],
                    config: .missing, accountTokensStored: ["github": true])
            ),
            (
                "config", "edit_config",
                SetupStatusComputer(
                    host: host(), clt: .ok(version: "27.0"), tartHealth: .healthy, tartList: [vm(name: "tahoe-base")],
                    config: .template, accountTokensStored: ["github": true])
            ),
            (
                "account-token-github", "enter_account_token",
                SetupStatusComputer(
                    host: host(), clt: .ok(version: "27.0"), tartHealth: .healthy, tartList: [vm(name: "tahoe-base")],
                    config: .loaded(config()), accountTokensStored: ["github": false])
            ),
            (
                "image", "prepare_image",
                SetupStatusComputer(
                    host: host(), clt: .ok(version: "27.0"), tartHealth: .healthy, tartList: [vm(name: "unrelated")],
                    config: .loaded(config()), accountTokensStored: ["github": true])
            ),
        ]
        for (id, expectedAction, computer) in cases {
            let status = await computer.compute()
            XCTAssertEqual(
                status.checks.first { $0.id == id }?.action, expectedAction,
                "\(id) with its failing state should repair via \(expectedAction)")
        }
    }

}
