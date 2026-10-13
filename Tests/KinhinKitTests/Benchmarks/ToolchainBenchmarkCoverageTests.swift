import XCTest

@testable import KinhinKit

/// The "every toolchain" guarantee: adding a catalog tool or stack without a
/// bench plan (an installer, its verify command, a workload or an explicit
/// skip reason) fails here, the way `ToolchainCatalogInvariantTests` guards
/// the catalog itself.
final class ToolchainBenchmarkCoverageTests: XCTestCase {
    func testEveryToolAndStackYieldsAPlanOnEachPlatformItClaims() {
        for platform in ToolchainPlatform.allCases {
            let plans = ToolchainBenchPlan.plans(platform: platform)
            let ids = Set(plans.map(\.id))
            for tool in ToolchainCatalog.tools where tool.platforms.contains(platform) {
                XCTAssertTrue(ids.contains(tool.id), "\(tool.id) has no bench plan on \(platform)")
            }
            for stack in ToolchainCatalog.stacks where stack.platforms.contains(platform) {
                XCTAssertTrue(ids.contains(stack.id), "\(stack.id) has no bench plan on \(platform)")
            }
            let unclaimed =
                ToolchainCatalog.tools.filter { !$0.platforms.contains(platform) }.map(\.id)
                + ToolchainCatalog.stacks.filter { !$0.platforms.contains(platform) }.map(\.id)
            for id in unclaimed { XCTAssertFalse(ids.contains(id), "\(id) does not claim \(platform)") }
        }
    }

    func testEveryPlanHasAnInstallerAVerifyAndAWorkloadOrASkipReason() {
        for platform in ToolchainPlatform.allCases {
            for plan in ToolchainBenchPlan.plans(platform: platform) {
                let label = "\(plan.id) on \(platform)"
                XCTAssertFalse(plan.installer.isEmpty, "\(label): no installer")
                XCTAssertFalse(plan.verify.isEmpty, "\(label): no verify command")
                XCTAssertNotNil(ToolchainWorkloads.workload(for: plan.id), "\(label): no workload entry")
                switch plan.workload {
                case .script(let name, let body):
                    XCTAssertFalse(name.isEmpty, label)
                    XCTAssertFalse(body.isEmpty, label)
                case .skip(let reason):
                    XCTAssertFalse(reason.isEmpty, "\(label): a skipped workload must say why")
                }
                let installs =
                    !plan.selection.miseSpecs.isEmpty || !plan.selection.npmPackages.isEmpty
                    || !plan.selection.aptPackages.isEmpty || !plan.selection.brewFormulas.isEmpty
                    || !plan.selection.gems.isEmpty || !plan.selection.stackSteps.isEmpty
                XCTAssertTrue(installs, "\(label): resolves to nothing to install")
                XCTAssertTrue(
                    plan.selection.verifications.contains(plan.verify), "\(label): verify not in the selection")
            }
        }
    }

    func testTheWorkloadTableHasNoStaleEntries() {
        let known = Set(ToolchainCatalog.tools.map(\.id) + ToolchainCatalog.stacks.map(\.id))
        for id in ["definitely-not-a-tool"] { XCTAssertNil(ToolchainWorkloads.workload(for: id)) }
        for id in known { XCTAssertNotNil(ToolchainWorkloads.workload(for: id), id) }
    }

    func testWorkloadsNeverFetchAnythingOrTouchCredentials() {
        let forbidden = [
            "curl ", "wget ", "http://", "https://", "git clone", " npm install", "pip install", "brew install",
            "GH_TOKEN", "AWS_", "VERCEL_TOKEN", "CLOUDFLARE_API_TOKEN", "sudo ",
        ]
        for plan in ToolchainBenchPlan.plans(platform: .macOS) + ToolchainBenchPlan.plans(platform: .linux) {
            guard case .script(_, let body) = plan.workload else { continue }
            for needle in forbidden {
                XCTAssertFalse(body.contains(needle), "\(plan.id) workload contains '\(needle)'")
            }
        }
    }

    func testTheColdInstallScriptCarriesNoCacheMount() {
        for platform in ToolchainPlatform.allCases {
            for plan in ToolchainBenchPlan.plans(platform: platform) {
                for root in [true, false] {
                    let script = plan.installScript(runsAsRoot: root)
                    for needle in [
                        "kinhin-cache", "toolchain-cache", "My Shared Files", "export MISE_CACHE_DIR",
                        "export NPM_CONFIG_CACHE", "export GOMODCACHE", "export HOMEBREW_CACHE",
                    ] {
                        XCTAssertFalse(
                            script.contains(needle), "\(plan.id) on \(platform): cold install mentions \(needle)")
                    }
                }
            }
        }
    }

    func testAMiseToolInstallsExactlyItsOwnSpec() throws {
        let node = try XCTUnwrap(ToolchainBenchPlan.plans(platform: .macOS, ids: ["node"]).first)
        let pin = try XCTUnwrap(ToolchainCatalog.tool(id: "node")).defaultSpec
        XCTAssertEqual(node.installer, "mise \(pin)")
        XCTAssertTrue(node.installScript(runsAsRoot: true).contains("mise use --global '\(pin)'"))
        XCTAssertFalse(node.installScript(runsAsRoot: true).contains("go@"))
    }

    func testRequirementsAreResolvedAndOrderedFirst() throws {
        let plans = ToolchainBenchPlan.plans(platform: .macOS, ids: ["typescript", "node"])
        XCTAssertEqual(plans.map(\.id), ["node", "typescript"], "a plan with requirements follows the ones without")
        XCTAssertEqual(plans.last?.requires, ["node"])
    }

    func testThoroughGroupingKeepsACategoryTogether() {
        let plans = ToolchainBenchPlan.plans(platform: .macOS, ids: ["typescript", "jq", "node", "terraform", "go"])
        let grouped = ToolchainBenchmark.grouped(plans, byCategory: true)
        XCTAssertEqual(
            grouped.map(\.category),
            grouped.map(\.category).sorted { lhs, rhs in
                (ToolchainCategory.allCases.firstIndex(of: lhs) ?? 0)
                    < (ToolchainCategory.allCases.firstIndex(of: rhs) ?? 0)
            })
        XCTAssertEqual(grouped.map(\.id).prefix(2).sorted(), ["go", "node"])
        XCTAssertEqual(ToolchainBenchmark.grouped(plans, byCategory: false).map(\.id), plans.map(\.id))
    }

    func testPlatformOnlyEntriesStayOnTheirPlatform() {
        XCTAssertNotNil(ToolchainBenchPlan.plans(platform: .macOS, ids: ["react-native"]).first)
        XCTAssertTrue(ToolchainBenchPlan.plans(platform: .linux, ids: ["react-native"]).isEmpty)
        XCTAssertEqual(
            ToolchainBenchPlan.plans(platform: .linux, ids: ["dotnet"]).first?.installer, "apt dotnet-sdk-8.0")
        XCTAssertEqual(
            ToolchainBenchPlan.plans(platform: .macOS, ids: ["dotnet"]).first?.installer, "brew cask dotnet-sdk")
    }
}
