import Security
import Synchronization
import XCTest

@testable import KinhinKit
@testable import KinhinTestSupport

/// The reset core: per-scope planning, the ordered wipe, and the guarantees
/// the double confirmation leans on (the plan describes exactly what
/// execution removes; nothing outside the plan is touched).
final class ResetEverythingTests: XCTestCase {
    private var supportRoot: URL!
    private var configURL: URL!
    private var configBody: String {
        """
        accounts:
          - name: github
            forge: github
            scope: "acme/widgets"
        labels: [self-hosted]
        base_image: "tahoe-base"
        images:
          - name: xcode-base
        """
    }

    override func setUpWithError() throws {
        supportRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("kinhin-reset-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: supportRoot, withIntermediateDirectories: true)
        configURL = supportRoot.appendingPathComponent("config.yaml")
        try configBody.write(to: configURL, atomically: true, encoding: .utf8)
        // Tokens land on a throwaway keychain service; legacy items are never
        // touched while the override is set.
        KeychainTokenStore.serviceOverride = "com.kinhin.runner.tests.\(UUID().uuidString)"
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: supportRoot)
        // The scratch service's items go too, or every run leaks Keychain items.
        _ = try? KeychainTokenStore.deleteAll(service: KeychainTokenStore.service)
        KeychainTokenStore.serviceOverride = nil
    }

    private func makeTart() -> FakeTart {
        let tart = FakeTart()
        tart.vms = [
            "kinhin-1": TartVM(name: "kinhin-1", source: "tahoe-base", status: "stopped"),
            "kinhin-prepare-tmp-7": TartVM(name: "kinhin-prepare-tmp-7", source: "tahoe-base", status: "stopped"),
            "tahoe-base": TartVM(name: "tahoe-base", source: "", status: "stopped"),
            "xcode-base": TartVM(name: "xcode-base", source: "tahoe-base", status: "stopped"),
            "my-own-vm": TartVM(name: "my-own-vm", source: "", status: "stopped"),
        ]
        return tart
    }

    /// Lays out a realistic support directory: logs, state, toolchain cache,
    /// plus a foreign file reset must not invent a reason to keep.
    private func populateSupportDirectory() throws {
        try FileManager.default.createDirectory(
            at: supportRoot.appendingPathComponent("logs"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: supportRoot.appendingPathComponent("state"), withIntermediateDirectories: true)
        let cache = supportRoot.appendingPathComponent("toolchain-cache")
        try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
        try Data("log".utf8).write(to: supportRoot.appendingPathComponent("logs/kinhin.log"))
        try Data("{}".utf8).write(to: supportRoot.appendingPathComponent("state/fleet.json"))
        try Data(repeating: 9, count: 4096).write(to: cache.appendingPathComponent("brew"))
        let backup = configURL.appendingPathExtension("bak")
        try configBody.write(to: backup, atomically: true, encoding: .utf8)
    }

    private func saveTokens() throws {
        do {
            try KeychainTokenStore.save("token-a", forge: .github)
            try KeychainTokenStore.save("token-b", forge: .gitea)
            try KeychainTokenStore.save("token-c", forge: .github, name: "work")
        } catch KeychainTokenStore.TokenError.unhandled(let status) where status == errSecInteractionNotAllowed {
            // A headless runner session (kinhin's own CI VM) cannot write the
            // login keychain; the token wipe is covered wherever it can.
            throw XCTSkip("login keychain is not writable in this session")
        }
    }

    // MARK: - Planning

    func testConfigScopePlansFilesTokensAndNotTheDaemon() async throws {
        try populateSupportDirectory()
        try saveTokens()
        let plan = try await ResetEverything.plan(
            scope: .config, configURL: configURL, supportRoot: supportRoot,
            isDaemonAlive: { true })
        XCTAssertEqual(plan.scope, .config)
        XCTAssertEqual(plan.configFiles, [configURL, configURL.appendingPathExtension("bak")])
        XCTAssertEqual(plan.keychainAccounts, ["gitea-pat", "github-pat", "github-pat:work"], "sorted")
        XCTAssertFalse(plan.daemonInstalled, "the config scope never touches the daemon")
        XCTAssertTrue(plan.daemonAlive, "informational: a daemon was alive at plan time")
        XCTAssertNil(plan.cleanup)
        XCTAssertFalse(plan.configBroken)
    }

    func testMissingConfigIsNotBrokenButUnreadableOneIs() async throws {
        try FileManager.default.removeItem(at: configURL)
        let missing = try await ResetEverything.plan(
            scope: .config, configURL: configURL, supportRoot: supportRoot)
        XCTAssertFalse(missing.configBroken, "no config yet is the normal first-run state")
        XCTAssertFalse(missing.configFiles.contains(configURL))

        try "accounts: [oops".write(to: configURL, atomically: true, encoding: .utf8)
        let broken = try await ResetEverything.plan(
            scope: .config, configURL: configURL, supportRoot: supportRoot)
        XCTAssertTrue(broken.configBroken, "bad YAML is flagged so the plan can say image names are guesses")
    }

    func testDaemonScopePlansStopAndUninstallOnly() async throws {
        let plan = try await ResetEverything.plan(
            scope: .daemon, configURL: configURL, supportRoot: supportRoot,
            isDaemonAlive: { true })
        XCTAssertTrue(plan.daemonAlive)
        XCTAssertNil(plan.cleanup)
        XCTAssertTrue(plan.configFiles.isEmpty, "the daemon scope keeps the config")
        XCTAssertTrue(plan.keychainAccounts.isEmpty, "the daemon scope keeps the tokens")
    }

    func testAllScopePlansVMsImagesCacheAndEverythingElse() async throws {
        try populateSupportDirectory()
        try saveTokens()
        let tart = makeTart()
        let plan = try await ResetEverything.plan(
            scope: .all, configURL: configURL, supportRoot: supportRoot,
            isDaemonAlive: { false }, tart: tart)
        let cleanup = try XCTUnwrap(plan.cleanup)
        XCTAssertEqual(cleanup.vms, ["kinhin-1"], "only kinhin's runner VMs, never a foreign one")
        XCTAssertEqual(cleanup.scratchVMs, ["kinhin-prepare-tmp-7"])
        XCTAssertEqual(cleanup.images, ["tahoe-base", "xcode-base"])
        XCTAssertEqual(cleanup.cacheBytes, 4096)
        XCTAssertEqual(plan.configFiles.count, 2, "config and its backup")
        XCTAssertEqual(plan.keychainAccounts.count, 3)
    }

    func testPlanDescribeListsExactlyWhatExecutionRemoves() async throws {
        try populateSupportDirectory()
        try saveTokens()
        let plan = try await ResetEverything.plan(
            scope: .all, configURL: configURL, supportRoot: supportRoot,
            isDaemonAlive: { true }, tart: makeTart())
        let text = plan.describe()
        XCTAssertTrue(text.contains("kinhin reset — Everything"), text)
        XCTAssertTrue(text.contains("stop the fleet"), text)
        XCTAssertTrue(text.contains("LaunchAgent"), text)
        XCTAssertTrue(text.contains("kinhin-1"), text)
        XCTAssertTrue(text.contains("xcode-base"), text)
        XCTAssertTrue(text.contains("toolchain cache"), text)
        XCTAssertTrue(text.contains("3 keychain token(s)"), text)
        XCTAssertTrue(text.contains("this cannot be undone"), text)

        let configPlan = try await ResetEverything.plan(
            scope: .config, configURL: configURL, supportRoot: supportRoot, isDaemonAlive: { true })
        let configText = configPlan.describe()
        XCTAssertTrue(configText.contains("Config & credentials"), configText)
        XCTAssertTrue(configText.contains("are kept"), configText)
        XCTAssertTrue(configText.contains("the running daemon keeps serving"), configText)
    }

    // MARK: - Execution

    /// A hermetic execute: recording seams for everything that could leave
    /// the test process (fleet stop, LaunchAgent removal, support dirs).
    private func executeHermetically(
        _ plan: ResetPlan, tart: (any TartControlling)? = nil,
        uninstallCalls: inout Int, stopCalls: inout Int
    ) async throws -> ResetReport {
        let uninstall = Locked(0)
        let stop = Locked(0)
        let report = try await ResetEverything.execute(
            plan, tart: tart, shell: FakeShell(),
            stopFleet: { stop.withLock { $0 += 1 } },
            uninstallDaemon: { uninstall.withLock { $0 += 1 } },
            ensureDirs: {})
        uninstallCalls = uninstall.withLock { $0 }
        stopCalls = stop.withLock { $0 }
        return report
    }

    func testConfigScopeExecutionRemovesFilesAndTokensButKeepsTheRest() async throws {
        try populateSupportDirectory()
        try saveTokens()
        try Data("keep".utf8).write(to: supportRoot.appendingPathComponent("foreign.txt"))
        let plan = try await ResetEverything.plan(
            scope: .config, configURL: configURL, supportRoot: supportRoot, isDaemonAlive: { true })
        var uninstallCalls = 0, stopCalls = 0
        let report = try await executeHermetically(plan, uninstallCalls: &uninstallCalls, stopCalls: &stopCalls)

        XCTAssertEqual(stopCalls, 0, "the config scope never stops the fleet")
        XCTAssertEqual(uninstallCalls, 0, "the config scope never uninstalls the daemon")
        XCTAssertFalse(FileManager.default.fileExists(atPath: configURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: configURL.appendingPathExtension("bak").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: supportRoot.appendingPathComponent("logs").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: supportRoot.appendingPathComponent("state").path))
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: supportRoot.appendingPathComponent("foreign.txt").path),
            "only kinhin's own files go")
        XCTAssertTrue(FileManager.default.fileExists(atPath: supportRoot.path), "the directory itself survives")
        XCTAssertTrue(try KeychainTokenStore.load(forge: .github) == nil)
        XCTAssertTrue(try KeychainTokenStore.load(forge: .gitea) == nil)
        XCTAssertTrue(try KeychainTokenStore.load(forge: .github, name: "work") == nil)
        XCTAssertTrue(
            report.completed.contains("removed config, logs and state"), report.completed.joined(separator: "\n"))
        XCTAssertTrue(
            report.completed.contains("removed 3 keychain token(s)"), report.completed.joined(separator: "\n"))
    }

    func testDaemonScopeExecutionOnlyStopsAndUninstalls() async throws {
        try populateSupportDirectory()
        try saveTokens()
        let plan = try await ResetEverything.plan(
            scope: .daemon, configURL: configURL, supportRoot: supportRoot, isDaemonAlive: { true })
        var uninstallCalls = 0, stopCalls = 0
        let report = try await executeHermetically(plan, uninstallCalls: &uninstallCalls, stopCalls: &stopCalls)

        XCTAssertEqual(stopCalls, 1, "a running daemon's fleet is stopped first")
        XCTAssertEqual(uninstallCalls, 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: configURL.path), "the config stays")
        XCTAssertEqual(try KeychainTokenStore.load(forge: .github), "token-a", "the tokens stay")
        XCTAssertTrue(report.completed.contains("stopped the fleet"), report.completed.joined(separator: "\n"))
        XCTAssertTrue(
            report.completed.contains("removed the daemon LaunchAgent"), report.completed.joined(separator: "\n"))
    }

    func testDaemonScopeWithoutARunningDaemonSkipsTheStop() async throws {
        let plan = try await ResetEverything.plan(
            scope: .daemon, configURL: configURL, supportRoot: supportRoot, isDaemonAlive: { false })
        var uninstallCalls = 0, stopCalls = 0
        let report = try await executeHermetically(plan, uninstallCalls: &uninstallCalls, stopCalls: &stopCalls)
        XCTAssertEqual(stopCalls, 0)
        XCTAssertEqual(uninstallCalls, 1)
        XCTAssertFalse(report.completed.contains("stopped the fleet"))
    }

    func testAllScopeExecutionWipesEverythingUnderTheSupportRoot() async throws {
        try populateSupportDirectory()
        try saveTokens()
        let tart = makeTart()
        let plan = try await ResetEverything.plan(
            scope: .all, configURL: configURL, supportRoot: supportRoot,
            isDaemonAlive: { true }, tart: tart)
        var uninstallCalls = 0, stopCalls = 0
        let report = try await executeHermetically(
            plan, tart: tart, uninstallCalls: &uninstallCalls, stopCalls: &stopCalls)

        XCTAssertEqual(stopCalls, 1)
        XCTAssertEqual(uninstallCalls, 1)
        // VMs: kinhin's only — the scratch VM included, the foreign one never.
        XCTAssertEqual(
            Set(tart.deleteCalls), ["kinhin-1", "kinhin-prepare-tmp-7", "tahoe-base", "xcode-base"])
        XCTAssertFalse(tart.deleteCalls.contains("my-own-vm"))
        // The support root is emptied but kept.
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: supportRoot.path), [])
        XCTAssertTrue(FileManager.default.fileExists(atPath: supportRoot.path))
        XCTAssertTrue(try KeychainTokenStore.load(forge: .github) == nil)
        XCTAssertTrue(
            report.completed.contains("removed 2 VM(s) and 2 image(s)"), report.completed.joined(separator: "\n"))
        XCTAssertTrue(
            report.completed.contains("emptied \(supportRoot.path)"), report.completed.joined(separator: "\n"))
    }

    func testOneFailedVMDoesNotStrandTheOthers() async throws {
        try populateSupportDirectory()
        let tart = makeTart()
        tart.failNext("delete", stderr: "injected failure")  // kinhin-1 (sorted first) fails once
        let plan = try await ResetEverything.plan(
            scope: .all, configURL: configURL, supportRoot: supportRoot,
            isDaemonAlive: { false }, tart: tart)
        var uninstallCalls = 0, stopCalls = 0
        _ = try await executeHermetically(plan, tart: tart, uninstallCalls: &uninstallCalls, stopCalls: &stopCalls)
        XCTAssertTrue(
            tart.deleteCalls.contains("kinhin-prepare-tmp-7") && tart.deleteCalls.contains("tahoe-base"),
            "a failed delete must not strand the rest: \(tart.deleteCalls)")
    }

    func testAllScopeWithoutTartReportsTheLeftoversInsteadOfThrowing() async throws {
        try populateSupportDirectory()
        var plan = try await ResetEverything.plan(
            scope: .all, configURL: configURL, supportRoot: supportRoot, isDaemonAlive: { false },
            tart: FakeTart())
        // A nonexistent tart binary: the controller cannot be built, so the
        // VM/image steps are skipped and reported as left behind.
        plan.tartPath = "/nonexistent/kinhin-test-tart"
        plan.cleanup = CleanupPlan(vms: ["kinhin-1"], images: ["tahoe-base"], cacheBytes: nil)
        var uninstallCalls = 0, stopCalls = 0
        let report = try await executeHermetically(
            plan, tart: nil, uninstallCalls: &uninstallCalls, stopCalls: &stopCalls)
        XCTAssertFalse(report.isComplete)
        XCTAssertTrue(
            report.leftBehind.contains(where: {
                $0.contains("tart is not available") && $0.contains("2 VM(s)/image(s)")
            }),
            "a missing tart is reported, not fatal: \(report.leftBehind)")
        XCTAssertFalse(
            report.completed.contains(where: { $0.hasPrefix("removed 1 VM") }),
            "nothing was removed, so nothing is claimed: \(report.completed)")
    }

    // MARK: - Planning problems

    func testAFailingTartListIsAPlanningProblemAndTheResetIsNotComplete() async throws {
        try populateSupportDirectory()
        let tart = makeTart()
        tart.failList = true
        let plan = try await ResetEverything.plan(
            scope: .all, configURL: configURL, supportRoot: supportRoot, isDaemonAlive: { false },
            tart: tart, keychainAccounts: { [] })
        XCTAssertEqual(plan.planningProblems.map(\.area), [.tart])
        let message = try XCTUnwrap(plan.planningProblems.first?.message)
        XCTAssertTrue(message.contains("could not list Tart VMs"), message)
        XCTAssertTrue(message.contains("VMs and images were not removed"), message)
        XCTAssertEqual(plan.cleanup?.vms, [], "an unlisted tart contributes no VMs")
        XCTAssertEqual(plan.cleanup?.cacheBytes, 4096, "the cache is still counted")
        XCTAssertTrue(plan.describe().contains("warning: could not list Tart VMs"), "shown before confirming")

        var uninstallCalls = 0, stopCalls = 0
        let report = try await executeHermetically(
            plan, tart: tart, uninstallCalls: &uninstallCalls, stopCalls: &stopCalls)
        XCTAssertFalse(report.isComplete, "a reset that could not see the VMs is not a success")
        XCTAssertEqual(report.leftBehind.first, message)
    }

    func testAFailingKeychainReadIsAPlanningProblem() async throws {
        let plan = try await ResetEverything.plan(
            scope: .config, configURL: configURL, supportRoot: supportRoot, isDaemonAlive: { false },
            keychainAccounts: { throw KeychainTokenStore.TokenError.unhandled(errSecInteractionNotAllowed) })
        XCTAssertEqual(plan.planningProblems.map(\.area), [.keychain])
        let message = try XCTUnwrap(plan.planningProblems.first?.message)
        XCTAssertTrue(message.contains("could not read the Keychain"), message)
        XCTAssertTrue(message.contains("tokens were not listed"), message)
        XCTAssertTrue(plan.keychainAccounts.isEmpty)
        XCTAssertTrue(plan.describe().contains("warning: could not read the Keychain"), plan.describe())
    }

    func testAnExplicitTartPathThatIsMissingIsAPlanningProblem() async throws {
        try (configBody + "\ntart_path: /nonexistent/kinhin-test-tart\n")
            .write(to: configURL, atomically: true, encoding: .utf8)
        let plan = try await ResetEverything.plan(
            scope: .all, configURL: configURL, supportRoot: supportRoot, isDaemonAlive: { false },
            keychainAccounts: { [] })
        XCTAssertEqual(plan.planningProblems.map(\.area), [.tart])
        XCTAssertTrue(plan.planningProblems[0].message.contains("could not run tart"), plan.planningProblems[0].message)
    }

    func testTheHappyPathHasNoPlanningProblemsAndCompletes() async throws {
        try populateSupportDirectory()
        let tart = makeTart()
        let plan = try await ResetEverything.plan(
            scope: .all, configURL: configURL, supportRoot: supportRoot, isDaemonAlive: { false },
            tart: tart, keychainAccounts: { [] })
        XCTAssertEqual(plan.planningProblems, [])
        XCTAssertFalse(plan.describe().contains("warning:"), plan.describe())
        var uninstallCalls = 0, stopCalls = 0
        let report = try await executeHermetically(
            plan, tart: tart, uninstallCalls: &uninstallCalls, stopCalls: &stopCalls)
        XCTAssertTrue(report.isComplete, "\(report.leftBehind)")
        XCTAssertTrue(report.completed.contains("removed 2 VM(s) and 2 image(s)"), "\(report.completed)")
    }

    func testAFailedVMDeleteIsReportedAsLeftBehind() async throws {
        try populateSupportDirectory()
        let tart = makeTart()
        tart.failNext("delete", stderr: "injected failure")
        let plan = try await ResetEverything.plan(
            scope: .all, configURL: configURL, supportRoot: supportRoot, isDaemonAlive: { false },
            tart: tart, keychainAccounts: { [] })
        var uninstallCalls = 0, stopCalls = 0
        let report = try await executeHermetically(
            plan, tart: tart, uninstallCalls: &uninstallCalls, stopCalls: &stopCalls)
        XCTAssertFalse(report.isComplete)
        XCTAssertTrue(
            report.leftBehind.contains(where: { $0.hasPrefix("could not delete VM kinhin-1") }), "\(report.leftBehind)")
        XCTAssertTrue(report.completed.contains("removed 1 VM(s) and 2 image(s)"), "\(report.completed)")
    }

    func testAnUnlistableSupportDirectoryIsReportedAsLeftBehind() async throws {
        var plan = ResetPlan(scope: .all, supportRoot: supportRoot.appendingPathComponent("missing-dir"))
        plan.cleanup = CleanupPlan()
        var uninstallCalls = 0, stopCalls = 0
        let report = try await executeHermetically(plan, uninstallCalls: &uninstallCalls, stopCalls: &stopCalls)
        XCTAssertTrue(
            report.leftBehind.contains(where: { $0.contains("nothing in it was removed") }), "\(report.leftBehind)")
        XCTAssertFalse(report.completed.contains(where: { $0.hasPrefix("emptied") }), "\(report.completed)")
    }
}
