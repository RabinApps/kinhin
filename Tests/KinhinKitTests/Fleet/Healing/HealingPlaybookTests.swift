import XCTest

@testable import KinhinKit

/// The rules: which fixes answer which problem, and what the advisor may pick from.
final class HealingPlaybookTests: XCTestCase {
    private let pruning = HealingPlaybook.Context(cacheAutoPrune: true)
    private let noPruning = HealingPlaybook.Context(cacheAutoPrune: false)

    private func fixes(_ signal: HealingSignal, _ context: HealingPlaybook.Context? = nil) -> [Remediation] {
        HealingPlaybook.remediations(for: signal, context: context ?? pruning)
    }

    func testAVanishedInstanceIsRecycled() {
        let signal = HealingSignal(kind: .instanceGone, subject: "kinhin-1-a", detail: "gone")
        XCTAssertEqual(fixes(signal), [Remediation(.recycleInstance, subject: "kinhin-1-a")])
        XCTAssertEqual(fixes(signal).first?.tier, .automatic)
    }

    func testAStuckTeardownIsTheUsersToFinish() {
        let signal = HealingSignal(kind: .teardownStuck, subject: "kinhin-1-a", detail: "failed")
        XCTAssertEqual(fixes(signal).map(\.tier), [.manual])
    }

    func testDiskPressurePrunesTheCacheFirstThenAsksToPruneImages() {
        let signal = HealingSignal(kind: .diskPressure, detail: "full")
        XCTAssertEqual(fixes(signal).map(\.kind), [.pruneToolchainCache, .pruneImages])
        XCTAssertEqual(fixes(signal).map(\.tier), [.automatic, .approval])
    }

    func testDiskPressureLeavesACacheTheUserOptedOutOfPruning() {
        let signal = HealingSignal(kind: .diskPressure, detail: "full")
        XCTAssertEqual(fixes(signal, noPruning).map(\.kind), [.pruneImages])
    }

    func testSpawnFailuresFollowTheHealthProbe() {
        func kinds(_ runtime: RuntimeID, _ evidence: HealingSignal.Evidence?) -> [Remediation.Kind] {
            fixes(HealingSignal(kind: .spawnFailures, subject: runtime.rawValue, detail: "x", evidence: evidence))
                .map(\.kind)
        }
        XCTAssertEqual(kinds(.docker, .runtimeMissing), [.repairRuntime])
        XCTAssertEqual(kinds(.appleContainer, .containerSystemStopped), [.startContainerSystem])
        XCTAssertEqual(kinds(.tart, .tartKilledOnLaunch), [.repairTart])
        XCTAssertEqual(kinds(.tart, .tartBroken), [.repairTart])
        XCTAssertEqual(kinds(.docker, nil), [], "a healthy runtime that keeps failing has no rule")
        XCTAssertEqual(kinds(.docker, .runtimeBroken), [])
    }

    func testADetachedAccountIsRetriedUnlessItsTokenWasRejected() {
        let transient = HealingSignal(kind: .accountDetached, subject: "gitea", detail: "timed out")
        XCTAssertEqual(fixes(transient), [Remediation(.retryForgeAttach, subject: "gitea")])
        let rejected = HealingSignal(kind: .accountDetached, subject: "gitea", detail: "401", evidence: .authRejected)
        XCTAssertEqual(fixes(rejected), [Remediation(.replaceToken, subject: "gitea")])
        XCTAssertEqual(fixes(rejected).first?.tier, .manual, "tokens are never handled on their own")
    }

    func testUnreadableQueuesAndReconcileFailuresHaveNoRule() {
        XCTAssertEqual(fixes(HealingSignal(kind: .queueUnreadable, subject: "gitea", detail: "x")), [])
        XCTAssertEqual(fixes(HealingSignal(kind: .reconcileFailing, detail: "x")), [])
    }

    func testSetupChecksMapByTheirActionIDs() {
        func fix(_ id: String, _ action: String) -> Remediation? {
            fixes(HealingSignal(kind: .setupCheck, subject: id, detail: "x", setupAction: action)).first
        }
        XCTAssertEqual(fix("container-cli", "start_container_system"), Remediation(.startContainerSystem))
        XCTAssertEqual(fix("tart", "install_tart"), Remediation(.repairRuntime, subject: "tart"))
        XCTAssertEqual(fix("tart-rollback", "rollback_tart"), Remediation(.repairTart))
        XCTAssertEqual(fix("docker-cli", "install_docker"), Remediation(.repairRuntime, subject: "docker"))
        XCTAssertEqual(fix("host-agent", "install_host_agent"), Remediation(.repairRuntime, subject: "host"))
        XCTAssertEqual(
            fix("account-token-work", "replace_account_token"), Remediation(.replaceToken, subject: "work"))
        XCTAssertEqual(fix("image", "prepare_image")?.kind, .prepareImage)
        XCTAssertEqual(fix("container-kernel", "install_container_kernel")?.kind, .reviewSetup)
    }

    func testSlowHealingProblemsWaitBeforeAnythingActs() {
        XCTAssertEqual(HealingPlaybook.minimumAge(of: .instanceGone), 0)
        XCTAssertGreaterThan(HealingPlaybook.minimumAge(of: .queueUnreadable), 0)
        XCTAssertGreaterThan(
            HealingPlaybook.minimumAge(of: .teardownStuck), HealingPlaybook.minimumAge(of: .queueUnreadable))
    }

    // MARK: - Advisor candidates

    func testCandidatesFitTheSubject() {
        let spawn = HealingSignal(kind: .spawnFailures, subject: "appleContainer", detail: "x")
        XCTAssertEqual(
            HealingPlaybook.candidates(for: spawn, context: pruning).map(\.kind),
            [.repairRuntime, .startContainerSystem, .pruneImages])
        let queue = HealingSignal(kind: .queueUnreadable, subject: "gitea", detail: "x")
        XCTAssertEqual(
            HealingPlaybook.candidates(for: queue, context: pruning), [Remediation(.retryForgeAttach, subject: "gitea")]
        )
    }

    func testTokensAndSetupAreNeverOfferedToTheAdvisor() {
        XCTAssertEqual(
            HealingPlaybook.candidates(for: HealingSignal(kind: .credentials, detail: "x"), context: pruning), [])
        let setup = HealingSignal(kind: .setupCheck, subject: "tart", detail: "x", setupAction: "install_tart")
        XCTAssertEqual(HealingPlaybook.candidates(for: setup, context: pruning), [])
    }

    func testNoCandidateIsEverManual() {
        for kind in HealingSignal.Kind.allCases {
            let signal = HealingSignal(kind: kind, subject: "docker", detail: "x")
            for fix in HealingPlaybook.candidates(for: signal, context: pruning) {
                XCTAssertNotEqual(fix.tier, .manual, "\(kind) offers \(fix.kind)")
            }
        }
    }
}
