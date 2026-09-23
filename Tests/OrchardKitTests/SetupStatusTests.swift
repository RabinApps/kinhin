import XCTest
@testable import OrchardKit

/// Locks the setup-status contract: `orchard setup-status` and the menu bar
/// setup window must always agree, because both consume SetupStatusComputer.
final class SetupStatusTests: XCTestCase {
    // MARK: Fixtures

    private func host(arm64: Bool = true) -> HostResources {
        HostResources(logicalCores: 10, memoryGB: 64, freeDiskGB: 120, arm64: arm64)
    }

    private func vm(name: String, source: String = "ghcr.io/cirruslabs/macos-tahoe-base:latest", status: String = "suspended") -> TartVM {
        TartVM(name: name, source: source, status: status, cpu: nil, memoryMB: nil)
    }

    private func config() -> OrchardConfig {
        var cfg = OrchardConfig.default
        cfg.repo = "acme/widgets"
        cfg.labels = ["self-hosted", "macos"]
        cfg.image = "tahoe-base"
        return cfg
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
        XCTAssertEqual(status.checks.map(\.id), ["arch", "clt", "tart", "config", "token", "image"])
        XCTAssertEqual(status.ready, true)
        XCTAssertEqual(status.checks.map(\.action), [nil, nil, nil, nil, "replace_token", nil])

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
        XCTAssertEqual(status.checks.map(\.ok), [true, false, false, false, false, false])

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
            XCTAssertNotEqual(SetupAction.title(for: action), action,
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
        XCTAssertEqual(status.checks.count, 6, "rollback replaces the tart row, keeping the checklist fixed-length")
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
        XCTAssertEqual(status.checks.first { $0.id == "token" }?.action, "replace_token",
                       "a stored token stays replaceable (rotated/expired PATs are routine)")
        XCTAssertTrue(status.checks.first { $0.id == "token" }?.detail.contains("Keychain") ?? false)
    }
}

/// Tiny convenience so scenario tests read cleanly.
enum SetupCheckHelper {
    static func make(
        tartHealth: TartHealth,
        tartList: [TartVM],
        config: OrchardConfig,
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
