import XCTest

@testable import KinhinKit

/// Guards the button-dispatch contract. Regression: buttons were wired with
/// row ids ("tart") while the UI dispatched on action ids ("install_tart"),
/// so every click was a silent no-op. These tests make that mismatch
/// impossible: every action the checklist can ever emit must be a known,
/// titled, handler-mapped action.
final class ActionCoverageTests: XCTestCase {
    /// The complete set of dispatch keys the setup window implements.
    /// A new action in SetupStatusComputer MUST be added here (and to the
    /// window's switch) or buttons silently stop working again.
    static let handledActions: Set<String> = [
        "fix_clt",
        "install_tart",
        "rollback_tart",
        "reinstall_tart",
        "create_config",
        "edit_config",
        "enter_token",
        "replace_token",
        "enter_gitea_token",
        "replace_gitea_token",
        "enter_account_token",
        "replace_account_token",
        "prepare_image",
        "install_container_cli",
        "start_container_system",
        "prepare_container_image",
        "repair_provision_script",
    ]

    private func computer(
        cltState: CLTState,
        tartHealth: TartHealth,
        configScenario: ConfigScenario,
        tokenStored: Bool,
        giteaTokenStored: Bool? = nil,
        containerHealth: RuntimeHealth? = nil,
        containerImages: [String]? = nil
    ) -> SetupStatusComputer {
        SetupStatusComputer(
            host: HostResources(logicalCores: 10, memoryGB: 64, freeDiskGB: 120, arm64: true),
            clt: cltState,
            tartHealth: tartHealth,
            tartList: [],
            config: configScenario,
            tokenStored: tokenStored,
            giteaTokenStored: giteaTokenStored,
            containerHealth: containerHealth,
            containerImages: containerImages
        )
    }

    private var fixtureConfig: KinhinConfig {
        var cfg = KinhinConfig.default
        cfg.repo = "acme/widgets"
        return cfg
    }

    /// A config that also declares the Gitea forge (adds the gitea-token row).
    private var giteaConfig: KinhinConfig {
        var cfg = fixtureConfig
        cfg.gitea = KinhinConfig.GiteaForgeConfig(
            instance: "https://gitea.example.com", scope: "acme", labels: ["macos:host"])
        return cfg
    }

    /// A config with two extra named accounts (adds account-token rows).
    private var accountsConfig: KinhinConfig {
        var cfg = fixtureConfig
        cfg.accounts = [
            AccountConfig(name: "work", forge: .github, scope: "bigco"),
            AccountConfig(name: "home", forge: .gitea, scope: "me", instance: "https://git.lan"),
        ]
        return cfg
    }

    /// A config that also enables the Apple-container runtime (adds the
    /// container rows).
    private var containerConfig: KinhinConfig {
        var cfg = fixtureConfig
        cfg.container = KinhinConfig.ContainerConfig(image: "kinhin-ci-linux")
        return cfg
    }

    /// A config that also declares `provision_script` (adds the
    /// provision-script row).
    private func provisionScriptConfig(path: String) -> KinhinConfig {
        var cfg = fixtureConfig
        cfg.provisionScript = path
        return cfg
    }

    /// The parsed result of the auto-created starter template (placeholder repo).
    private var templateConfig: KinhinConfig {
        var cfg = KinhinConfig.default
        cfg.repo = ConfigLoader.templateRepo
        return cfg
    }

    /// Collects every action across all reachable checklist states.
    func testEveryEmittableActionIsHandledAndTitled() async {
        let scenarios: [(String, SetupStatusComputer)] = [
            (
                "fresh machine",
                computer(cltState: .missing, tartHealth: .missing, configScenario: .missing, tokenStored: false)
            ),
            (
                "stored token",
                computer(
                    cltState: .ok(version: "27.0"), tartHealth: .healthy, configScenario: .loaded(fixtureConfig),
                    tokenStored: true)
            ),
            (
                "clt outdated",
                computer(
                    cltState: .outdated(version: "26.6", macOSVersion: "27.0"), tartHealth: .healthy,
                    configScenario: .loaded(fixtureConfig), tokenStored: true)
            ),
            (
                "template config",
                computer(
                    cltState: .ok(version: "27.0"), tartHealth: .missing, configScenario: .template, tokenStored: false)
            ),
            (
                "killed on launch",
                computer(
                    cltState: .ok(version: "27.0"), tartHealth: .killedOnLaunch, configScenario: .loaded(fixtureConfig),
                    tokenStored: true)
            ),
            (
                "broken tart",
                computer(
                    cltState: .ok(version: "27.0"), tartHealth: .broken("segfault"),
                    configScenario: .loaded(fixtureConfig), tokenStored: true)
            ),
            (
                "image missing",
                computer(
                    cltState: .ok(version: "27.0"), tartHealth: .healthy, configScenario: .loaded(fixtureConfig),
                    tokenStored: true)
            ),
            (
                "gitea configured, token missing",
                computer(
                    cltState: .ok(version: "27.0"), tartHealth: .healthy, configScenario: .loaded(giteaConfig),
                    tokenStored: true, giteaTokenStored: false)
            ),
            (
                "gitea token stored",
                computer(
                    cltState: .ok(version: "27.0"), tartHealth: .healthy, configScenario: .loaded(giteaConfig),
                    tokenStored: true, giteaTokenStored: true)
            ),
            (
                "extra accounts, one token missing",
                SetupStatusComputer(
                    host: HostResources(logicalCores: 10, memoryGB: 64, freeDiskGB: 120, arm64: true),
                    clt: .ok(version: "27.0"), tartHealth: .healthy, tartList: [],
                    config: .loaded(accountsConfig), tokenStored: true,
                    accountTokensStored: ["work": true, "home": false])
            ),
            (
                "container CLI missing",
                computer(
                    cltState: .ok(version: "27.0"), tartHealth: .healthy, configScenario: .loaded(containerConfig),
                    tokenStored: true, containerHealth: .missing(tool: "apple container", fix: "brew install container")
                )
            ),
            (
                "container service down",
                computer(
                    cltState: .ok(version: "27.0"), tartHealth: .healthy, configScenario: .loaded(containerConfig),
                    tokenStored: true,
                    containerHealth: .broken(
                        "the container system service is not running — start it with: container system start"))
            ),
            (
                "container image missing",
                computer(
                    cltState: .ok(version: "27.0"), tartHealth: .healthy, configScenario: .loaded(containerConfig),
                    tokenStored: true, containerHealth: .ready, containerImages: [])
            ),
            (
                "container fully ready",
                computer(
                    cltState: .ok(version: "27.0"), tartHealth: .healthy, configScenario: .loaded(containerConfig),
                    tokenStored: true, containerHealth: .ready, containerImages: ["kinhin-ci-linux"])
            ),
            (
                "provision script missing",
                computer(
                    cltState: .ok(version: "27.0"), tartHealth: .healthy,
                    configScenario: .loaded(provisionScriptConfig(path: "/nonexistent/kinhin-provision.sh")),
                    tokenStored: true)
            ),
        ]

        var emitted: Set<String> = []
        for (name, computer) in scenarios {
            let status = await computer.compute()
            for check in status.checks {
                if let action = check.action {
                    emitted.insert(action)
                    XCTAssertTrue(
                        Self.handledActions.contains(action),
                        "[\(name)] action '\(action)' (row '\(check.id)') has no handler — clicking its button would be a silent no-op"
                    )
                    XCTAssertNotEqual(
                        SetupAction.title(for: action), action,
                        "[\(name)] action '\(action)' lacks a human-readable title"
                    )
                }
            }
        }
        XCTAssertEqual(
            emitted,
            Self.handledActions,
            "checklist emits actions the fixture matrix didn't cover (or handles actions nothing emits)"
        )
    }

    /// The dispatch keys must differ from row ids where they historically
    /// collided — pinning the exact regression.
    func testActionIDsAreNotRowIDs() async {
        let status = await computer(
            cltState: .missing, tartHealth: .missing, configScenario: .missing, tokenStored: false
        ).compute()
        for check in status.checks {
            if let action = check.action {
                XCTAssertNotEqual(
                    action, check.id,
                    "action '\(action)' equals its row id — the dispatch-vs-identifier regression shape"
                )
            }
        }
    }

    /// An auto-created template must NOT satisfy the config check — the
    /// placeholder repo would otherwise let the fleet "start" against nothing.
    func testTemplateConfigIsNotMarkedReady() async {
        let status = await computer(
            cltState: .ok(version: "27.0"), tartHealth: .healthy, configScenario: .template, tokenStored: true
        ).compute()
        let configCheck = status.checks.first { $0.id == "config" }
        XCTAssertEqual(configCheck?.ok, false)
        XCTAssertEqual(configCheck?.action, "edit_config")
        XCTAssertTrue(configCheck?.detail.contains("set your repo") ?? false)
        XCTAssertFalse(status.ready, "template config must not make the machine ready")
    }

    /// The config states render three distinct outcomes.
    func testConfigCheckThreeStates() {
        var real = KinhinConfig.default
        real.repo = "acme/widgets"
        let ok = SetupStatusComputer.configCheck(.parsed(real), path: "/tmp/x.yaml")
        let template = SetupStatusComputer.configCheck(.templateConfig, path: "/tmp/x.yaml")
        let invalid = SetupStatusComputer.configCheck(.invalidFile, path: "/tmp/x.yaml")
        let missing = SetupStatusComputer.configCheck(.noFile, path: "/tmp/x.yaml")
        XCTAssertNil(ok.action, "a real config needs no action")
        XCTAssertEqual(template.action, "edit_config")
        XCTAssertEqual(invalid.action, "create_config")
        XCTAssertEqual(missing.action, "create_config")
        XCTAssertNotEqual(SetupAction.title(for: "edit_config"), "edit_config", "edit_config needs a human title")
    }

    /// The starter template parses to exactly the placeholder-repo config.
    func testTemplateParsesToTemplateConfig() throws {
        let parsed = try ConfigLoader.parse(ConfigLoader.template())
        XCTAssertTrue(ConfigLoader.isTemplate(parsed))
        XCTAssertEqual(parsed.repo, ConfigLoader.templateRepo)
    }

    /// Every action the row view-model exposes is the contract action, not the row id.
    func testRowViewModelCarriesActionIDForDispatch() {
        let check = SetupCheckResult(
            id: "tart", title: "Tart installed", ok: false, detail: "d", action: "install_tart")
        let row = SetupRowViewModel(check: check)
        XCTAssertEqual(row.actionID, "install_tart")
        XCTAssertEqual(row.actionTitle, "Install via Homebrew")
    }
}
