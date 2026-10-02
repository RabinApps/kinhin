import XCTest

@testable import KinhinKit
@testable import KinhinTestSupport

/// The pure restart policy: routing-only changes are the live-reload set;
/// everything else in the frozen engine config requires a rebuild.
final class ReloadRestartPolicyTests: XCTestCase {
    func testRestartPolicyMatrix() {
        let base = makeTestConfig()

        // Routing-only edits (applyReloaded's exact set) stay live.
        XCTAssertFalse(FleetEngine.restartRequired(from: base, to: base), "identical configs never restart")
        var routes = makeTestConfig()
        routes.runtimes = .init(
            defaultRuntime: "appleContainer", budget: ["tart": 0.5, "appleContainer": 0.5],
            routes: [.init(pattern: "acme/api", runtime: "appleContainer")])
        XCTAssertFalse(FleetEngine.restartRequired(from: base, to: routes), "routes/budget/default are hot-reloaded")
        var labels = makeTestConfig()
        labels.labels = ["kinhin", "extra"]
        XCTAssertFalse(FleetEngine.restartRequired(from: base, to: labels), "label edits reach the forge live")

        // Everything read from the frozen config restarts.
        func with(_ mutate: (inout KinhinConfig) -> Void) -> KinhinConfig {
            var cfg = base
            mutate(&cfg)
            return cfg
        }
        XCTAssertTrue(
            FleetEngine.restartRequired(
                from: base,
                to: with {
                    $0.accounts = [AccountConfig(name: "github", forge: .github, scope: "acme/other")]
                }),
            "scope change must restart")
        XCTAssertTrue(FleetEngine.restartRequired(from: base, to: with { $0.minRunners = 2 }), "bounds must restart")
        XCTAssertTrue(FleetEngine.restartRequired(from: base, to: with { $0.maxRunners = 8 }), "bounds must restart")
        XCTAssertTrue(FleetEngine.restartRequired(from: base, to: with { $0.runnersPerVM = 3 }), "density must restart")
        XCTAssertTrue(
            FleetEngine.restartRequired(from: base, to: with { $0.pollInterval = 60 }), "poll cadence must restart")
        XCTAssertTrue(
            FleetEngine.restartRequired(from: base, to: with { $0.autoResume = true }), "auto-resume must restart")
        XCTAssertTrue(FleetEngine.restartRequired(from: base, to: with { $0.vm.cpuCount = 6 }), "VM shape must restart")
        XCTAssertTrue(
            FleetEngine.restartRequired(from: base, to: with { $0.image = "other-base" }), "image must restart")
        XCTAssertTrue(
            FleetEngine.restartRequired(from: base, to: with { $0.reserve.cpu = 4 }), "host headroom must restart")
        XCTAssertTrue(
            FleetEngine.restartRequired(
                from: base, to: with { $0.container = .init(image: "linux", cpus: 2, memoryGB: 4) }),
            "runtime sections must restart")
        XCTAssertTrue(
            FleetEngine.restartRequired(
                from: base,
                to: with {
                    $0.accounts.append(
                        AccountConfig(
                            name: "gitea", forge: .gitea, scope: "acme", instance: "https://gitea.example.com"))
                }),
            "forge accounts must restart")
        XCTAssertTrue(
            FleetEngine.restartRequired(from: base, to: with { $0.toolchainCache = .init(maxGB: 10) }),
            "toolchain_cache must restart")
        XCTAssertFalse(
            FleetEngine.restartRequired(
                from: base,
                to: with {
                    $0.projects = [
                        .init(
                            pattern: "acme/widgets", repoFile: false,
                            toolchains: .init(specs: ["node@22"]), shareCache: true)
                    ]
                }),
            "projects hot-apply, they never restart")
    }
}
