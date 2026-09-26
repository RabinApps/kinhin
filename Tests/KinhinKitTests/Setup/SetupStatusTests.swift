import XCTest

@testable import KinhinKit

/// Locks the setup-status contract: `kinhin setup-status` and the menu bar
/// setup window must always agree, because both consume SetupStatusComputer.
final class SetupStatusTests: XCTestCase {
    // MARK: Fixtures

    private func host(arm64: Bool = true) -> HostResources {
        HostResources(logicalCores: 10, memoryGB: 64, freeDiskGB: 120, arm64: arm64)
    }

    private func vm(
        name: String, source: String = "ghcr.io/cirruslabs/macos-tahoe-base:latest", status: String = "suspended"
    ) -> TartVM {
        TartVM(name: name, source: source, status: status, cpu: nil, memoryMB: nil)
    }

    private func config() -> KinhinConfig {
        var cfg = KinhinConfig.default
        cfg.repo = "acme/widgets"
        cfg.labels = ["self-hosted", "macos"]
        cfg.image = "tahoe-base"
        return cfg
    }

    /// Writes content to a unique temp file for provision-script fixtures.
    private func writeTempScript(_ content: String) throws -> String {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("kinhin-setup-status-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("provision.sh")
        try content.write(to: url, atomically: true, encoding: .utf8)
        return url.path
    }

    // MARK: Contract

    func testCheckIDsAndActionsAreStable() async {
        let computer = SetupStatusComputer(
            host: host(),
            clt: .ok(version: "26.6"),
            tartHealth: .healthy,
            tartList: [vm(name: "tahoe-base")],
            config: .loaded(config()),
            tokenStored: true
        )
        let status = await computer.compute()

        // Without a container: config, the container rows never appear.
        XCTAssertEqual(status.checks.map(\.id), ["arch", "clt", "tart", "config", "token", "image", "toolchain-cache"])
        XCTAssertEqual(status.ready, true)
        XCTAssertEqual(status.checks.map(\.action), [nil, nil, nil, nil, "replace_token", nil, nil])

        // The JSON contract decodes cleanly (this is what --json emits).
        let data = try! JSONEncoder().encode(status)
        let decoded = try! JSONDecoder().decode(SetupStatus.self, from: data)
        XCTAssertEqual(decoded, status)
    }

    func testFreshMachineChecklist() async {
        // Everything missing: the canonical first-run state.
        let computer = SetupStatusComputer(
            host: host(),
            clt: .missing,
            tartHealth: .missing,
            tartList: [],
            config: .missing,
            tokenStored: false
        )
        let status = await computer.compute()

        XCTAssertEqual(status.ready, false)
        XCTAssertEqual(
            status.checks.map(\.ok), [true, false, false, false, false, false, true],
            "the terminal toolchain-cache row is advisory-green even on a fresh machine")

        let byID = Dictionary(uniqueKeysWithValues: status.checks.map { ($0.id, $0) })
        XCTAssertEqual(byID["clt"]?.action, "fix_clt")
        XCTAssertEqual(byID["tart"]?.action, "install_tart")
        XCTAssertEqual(byID["config"]?.action, "create_config")
        XCTAssertEqual(byID["token"]?.action, "enter_token")
        XCTAssertEqual(byID["image"]?.action, "prepare_image")
        XCTAssertNil(byID["arch"]?.action)
        // Image check defers to tart.
        XCTAssertTrue(byID["image"]?.detail.contains("after tart is installed") ?? false)
    }

    func testActionTitlesCoverEveryAction() {
        // Every action the contract can emit has a human-readable label shared
        // by both front ends.
        let labels = [
            "install_tart", "rollback_tart", "reinstall_tart",
            "create_config", "enter_token", "prepare_image",
        ]
        for action in labels {
            XCTAssertNotEqual(
                SetupAction.title(for: action), action,
                "\(action) must have a human-readable title")
        }
    }

    // MARK: Scenario matrix

    func testKilledOnLaunchProducesRollbackRow() async {
        let computer = SetupStatusComputer(
            host: host(),
            tartHealth: .killedOnLaunch,
            tartList: [],
            config: .loaded(config()),
            tokenStored: true
        )
        let status = await computer.compute()
        let rollback = status.checks.first { $0.id == "tart-rollback" }
        XCTAssertNotNil(rollback)
        XCTAssertEqual(rollback?.ok, false)
        XCTAssertEqual(rollback?.action, "rollback_tart")
        XCTAssertEqual(status.checks.count, 7, "rollback replaces the tart row; the advisory cache row appends")
        XCTAssertEqual(status.checks.map(\.id).contains("tart"), false)
        XCTAssertEqual(status.ready, false)
    }

    func testImageCheckUsesTartListFixture() async {
        let computer = SetupStatusComputer(
            host: host(),
            tartHealth: .healthy,
            tartList: [vm(name: "other-image"), vm(name: "tahoe-base")],
            config: .loaded(config()),
            tokenStored: true
        )
        let status = await computer.compute()
        let image = status.checks.first { $0.id == "image" }
        XCTAssertEqual(image?.ok, true)
        XCTAssertTrue(image?.detail.contains("tahoe-base") ?? false)
    }

    func testImageMissingWhenNotInTartList() async {
        let computer = SetupStatusComputer(
            host: host(),
            tartHealth: .healthy,
            tartList: [vm(name: "unrelated")],
            config: .loaded(config()),
            tokenStored: true
        )
        let status = await computer.compute()
        let image = status.checks.first { $0.id == "image" }
        XCTAssertEqual(image?.ok, false)
        XCTAssertEqual(image?.action, "prepare_image")
        XCTAssertTrue(image?.detail.contains("not local yet") ?? false)
    }

    func testImageNotRequiredToRunWhenTartBroken() async {
        let computer = SetupStatusComputer(
            host: host(),
            tartHealth: .broken("segfault"),
            tartList: nil,
            config: .loaded(config()),
            tokenStored: true
        )
        let status = await computer.compute()
        let image = status.checks.first { $0.id == "image" }
        XCTAssertEqual(image?.ok, false)
        XCTAssertTrue(image?.detail.contains("could not launch tart") ?? false)
    }

    func testImageRowSurfacesATartListFailure() async throws {
        // tart launches fine but `tart list` fails: the row must say why
        // instead of reporting a launch problem or showing nothing.
        let script = FileManager.default.temporaryDirectory
            .appendingPathComponent("fake-tart-\(UUID().uuidString)")
        try "#!/bin/sh\necho 'disk image locked' >&2\nexit 1\n".write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        defer { try? FileManager.default.removeItem(at: script) }  // temp fixture; leftover is harmless

        var cfg = config()
        cfg.tartPath = script.path
        let computer = SetupStatusComputer(
            host: host(),
            tartHealth: .healthy,
            tartList: nil,
            config: .loaded(cfg),
            tokenStored: true
        )
        let image = await computer.compute().checks.first { $0.id == "image" }
        XCTAssertEqual(image?.ok, false)
        XCTAssertTrue(image?.detail.contains("could not list tart images") ?? false, image?.detail ?? "")
        XCTAssertTrue(image?.detail.contains("disk image locked") ?? false, image?.detail ?? "")
    }

    func testNotArm64FailsArchCheck() async {
        let computer = SetupStatusComputer(
            host: host(arm64: false),
            tartHealth: .missing,
            tartList: [],
            config: .missing,
            tokenStored: false
        )
        let status = await computer.compute()
        XCTAssertEqual(status.checks.first { $0.id == "arch" }?.ok, false)
        XCTAssertEqual(status.ready, false)
    }

    func testInvalidConfigWithFilePresent() async {
        // Hermetic: the .invalid scenario means "file exists but doesn't parse",
        // regardless of what's on this machine's disk.
        let computer = SetupStatusComputer(
            host: host(),
            tartHealth: .healthy,
            tartList: [vm(name: "tahoe-base")],
            config: .invalid,
            tokenStored: true
        )
        let status = await computer.compute()
        let configCheck = status.checks.first { $0.id == "config" }
        XCTAssertEqual(configCheck?.ok, false)
        XCTAssertTrue(configCheck?.detail.contains("invalid") ?? false)
        XCTAssertEqual(configCheck?.action, "create_config")
    }

    func testStoredTokenProducesNoAction() async {
        let computer = SetupCheckHelper.make(
            tartHealth: .healthy,
            tartList: [vm(name: "tahoe-base")],
            config: config(),
            tokenStored: true
        )
        let status = await computer.compute()
        XCTAssertEqual(
            status.checks.first { $0.id == "token" }?.action, "replace_token",
            "a stored token stays replaceable (rotated/expired PATs are routine)")
        XCTAssertTrue(status.checks.first { $0.id == "token" }?.detail.contains("Keychain") ?? false)
    }

    // MARK: Provision script row — only when the config declares one

    private func configWithProvisionScript(_ path: String?) -> KinhinConfig {
        var cfg = config()
        cfg.provisionScript = path
        return cfg
    }

    func testProvisionScriptRowAbsentWithoutConfigKey() async {
        let computer = SetupStatusComputer(
            host: host(),
            clt: .ok(version: "27.0"),
            tartHealth: .healthy,
            tartList: [vm(name: "tahoe-base")],
            config: .loaded(configWithProvisionScript(nil)),
            tokenStored: true
        )
        let status = await computer.compute()
        XCTAssertNil(
            status.checks.first { $0.id == "provision-script" },
            "no provision_script in config → no row")
        XCTAssertEqual(status.checks.map(\.id), ["arch", "clt", "tart", "config", "token", "image", "toolchain-cache"])
        XCTAssertTrue(status.ready)
    }

    func testValidProvisionScriptProducesGreenRow() async throws {
        let path = try writeTempScript("#!/bin/bash\nmise install go@1.23.4\n")
        let computer = SetupStatusComputer(
            host: host(),
            clt: .ok(version: "27.0"),
            tartHealth: .healthy,
            tartList: [vm(name: "tahoe-base")],
            config: .loaded(configWithProvisionScript(path)),
            tokenStored: true
        )
        let status = await computer.compute()
        let row = status.checks.first { $0.id == "provision-script" }
        XCTAssertEqual(row?.ok, true)
        XCTAssertNil(row?.action)
        XCTAssertTrue(row?.detail.contains(path) ?? false, "detail names the script: \(row?.detail ?? "")")
        XCTAssertTrue(status.ready, "a valid script must not block readiness")
        // The row sits right after config, before tokens.
        XCTAssertEqual(
            status.checks.map(\.id),
            ["arch", "clt", "tart", "config", "provision-script", "token", "image", "toolchain-cache"])
    }

    func testMissingProvisionScriptProducesFixRowAndBlocksReady() async {
        let missing = "/nonexistent/kinhin-provision-\(UUID().uuidString).sh"
        let computer = SetupStatusComputer(
            host: host(),
            clt: .ok(version: "27.0"),
            tartHealth: .healthy,
            tartList: [vm(name: "tahoe-base")],
            config: .loaded(configWithProvisionScript(missing)),
            tokenStored: true
        )
        let status = await computer.compute()
        let row = status.checks.first { $0.id == "provision-script" }
        XCTAssertEqual(row?.ok, false)
        XCTAssertEqual(row?.action, "repair_provision_script")
        XCTAssertTrue(row?.detail.contains("missing or unreadable") ?? false)
        XCTAssertFalse(
            status.ready, "a broken provision script must block readiness — prepare would fail after the download")
        XCTAssertEqual(SetupAction.title(for: "repair_provision_script"), "Fix Provision Script…")
    }

    func testEmptyProvisionScriptProducesFixRow() async throws {
        let path = try writeTempScript("   \n\t\n")
        let computer = SetupStatusComputer(
            host: host(),
            clt: .ok(version: "27.0"),
            tartHealth: .healthy,
            tartList: [vm(name: "tahoe-base")],
            config: .loaded(configWithProvisionScript(path)),
            tokenStored: true
        )
        let status = await computer.compute()
        let row = status.checks.first { $0.id == "provision-script" }
        XCTAssertEqual(row?.ok, false)
        XCTAssertEqual(row?.action, "repair_provision_script")
        XCTAssertTrue(row?.detail.contains("is empty") ?? false, "detail must say why: \(row?.detail ?? "")")
        XCTAssertFalse(status.ready)
    }

    func testProvisionScriptDetailExpandsTildeLikePrepare() async {
        // The detail must show the expanded path (what prepare will use),
        // never the raw ~ form — a user must see the exact file being probed.
        let computer = SetupStatusComputer(
            host: host(),
            clt: .ok(version: "27.0"),
            tartHealth: .healthy,
            tartList: [vm(name: "tahoe-base")],
            config: .loaded(configWithProvisionScript("~/kinhin/provision-\(UUID().uuidString).sh")),
            tokenStored: true
        )
        let status = await computer.compute()
        let row = status.checks.first { $0.id == "provision-script" }
        XCTAssertEqual(row?.ok, false)
        let detail = row?.detail ?? ""
        XCTAssertFalse(detail.contains("~"), "detail must not show the tilde form: \(detail)")
        XCTAssertTrue(detail.contains("/kinhin/provision-"), "detail shows the expanded path: \(detail)")
    }

    // MARK: Shared toolchain cache row

    func testToolchainCacheRowAlwaysPresentAndNeverBlocksReady() async {
        // Unusable + share_cache on: the only red detail — but advisory, so
        // ready survives (a missing cache is regenerated by the next prepare).
        let computer = SetupStatusComputer(
            host: host(),
            clt: .ok(version: "26.6"),
            tartHealth: .healthy,
            tartList: [vm(name: "tahoe-base")],
            config: .loaded(config()),
            tokenStored: true,
            toolchainCacheState: (usable: false, shareCacheOn: true)
        )
        let status = await computer.compute()
        XCTAssertEqual(status.checks.map(\.id), ["arch", "clt", "tart", "config", "token", "image", "toolchain-cache"])
        let row = try! XCTUnwrap(status.checks.first { $0.id == "toolchain-cache" })
        XCTAssertEqual(row.action, "create_toolchain_cache")
        XCTAssertTrue(
            row.detail.contains("runner mounts will be empty"), "the detail names the consequence: \(row.detail)")
        XCTAssertTrue(status.ready, "the cache row is advisory — it never blocks onboarding")
    }

    func testToolchainCacheRowGreenWithShareCacheOn() async {
        let computer = SetupStatusComputer(
            host: host(),
            clt: .ok(version: "26.6"),
            tartHealth: .healthy,
            tartList: [vm(name: "tahoe-base")],
            config: .loaded(config()),
            tokenStored: true,
            toolchainCacheState: (usable: true, shareCacheOn: true)
        )
        let status = await computer.compute()
        let row = try! XCTUnwrap(status.checks.first { $0.id == "toolchain-cache" })
        XCTAssertEqual(row.ok, true)
        XCTAssertNil(row.action)
        XCTAssertTrue(row.detail.contains("share_cache on"))
    }

    func testToolchainCacheRowOffPointsAtTheConfigKey() async {
        let computer = SetupStatusComputer(
            host: host(),
            clt: .ok(version: "26.6"),
            tartHealth: .healthy,
            tartList: [vm(name: "tahoe-base")],
            config: .loaded(config()),
            tokenStored: true,
            toolchainCacheState: (usable: true, shareCacheOn: false)
        )
        let status = await computer.compute()
        let row = try! XCTUnwrap(status.checks.first { $0.id == "toolchain-cache" })
        XCTAssertEqual(row.ok, true)
        XCTAssertTrue(row.detail.contains("share_cache: true"), "the detail teaches the opt-in: \(row.detail)")
    }

    func testToolchainCacheActionTitleIsMapped() {
        XCTAssertEqual(SetupAction.title(for: "create_toolchain_cache"), "Create Toolchain Cache")
    }
}

/// Tiny fixture helpers for the provision-script row tests.
enum ProvisionScriptFixtures {}

/// Tiny convenience so scenario tests read cleanly.
enum SetupCheckHelper {
    static func make(
        tartHealth: TartHealth,
        tartList: [TartVM],
        config: KinhinConfig,
        tokenStored: Bool
    ) -> SetupStatusComputer {
        SetupStatusComputer(
            host: HostResources(logicalCores: 10, memoryGB: 64, freeDiskGB: 120, arm64: true),
            tartHealth: tartHealth,
            tartList: tartList,
            config: .loaded(config),
            tokenStored: tokenStored
        )
    }
}
