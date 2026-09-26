import Foundation

/// One prerequisite row of the first-run checklist. The JSON contract shared
/// by `kinhin setup-status` and the menu bar setup window — treat field
/// values (especially `id` and `action`) as a stable API.
public struct SetupCheckResult: Codable, Equatable, Sendable {
    /// Stable identifier: arch, tart, tart-rollback, config, token, image.
    public let id: String
    public let title: String
    public let ok: Bool
    /// Human-readable status line (contains no secrets).
    public let detail: String
    /// Stable action identifier for the fix button, or nil when nothing to do.
    public let action: String?

    public init(id: String, title: String, ok: Bool, detail: String, action: String?) {
        self.id = id
        self.title = title
        self.ok = ok
        self.detail = detail
        self.action = action
    }
}

/// The whole checklist plus whether onboarding is complete.
public struct SetupStatus: Codable, Equatable, Sendable {
    public let ready: Bool
    public let checks: [SetupCheckResult]

    public init(ready: Bool, checks: [SetupCheckResult]) {
        self.ready = ready
        self.checks = checks
    }
}

/// Human-readable labels for the stable action identifiers — shared so the
/// CLI and the app render the same fix-button text.
public enum SetupAction {
    public static func title(for action: String) -> String {
        switch action {
        case "fix_clt": return "Reinstall Command Line Tools"
        case "install_tart": return "Install via Homebrew"
        case "rollback_tart": return "Roll Back to Cirrus Build"
        case "reinstall_tart": return "Reinstall via Homebrew"
        case "create_config": return "Create Config"
        case "edit_config": return "Edit Config"
        case "enter_token": return "Enter Token…"
        case "replace_token": return "Replace Token…"
        case "enter_gitea_token": return "Enter Gitea Token…"
        case "replace_gitea_token": return "Replace Gitea Token…"
        case "enter_account_token": return "Enter Token…"
        case "replace_account_token": return "Replace Token…"
        case "install_container_cli": return "Install Apple container"
        case "install_docker": return "Install Docker"
        case "start_container_system": return "Start container system"
        case "install_container_kernel": return "Install Linux kernel"
        case "prepare_container_image": return "Prepare Container Image"
        case "prepare_docker_image": return "Prepare Docker Image"
        case "install_host_agent": return "Install Host Runner Agent"
        case "prepare_image": return "Prepare Image"
        case "repair_provision_script": return "Fix Provision Script…"
        case "create_toolchain_cache": return "Create Toolchain Cache"
        default: return action
        }
    }
}

/// Which config the checklist should see. `.live` probes the real machine;
/// every other case is a hermetic fixture for tests (and for callers that
/// already know the state). Replaces the old partial `configMissing` override.
public enum ConfigScenario: Sendable {
    /// Probe the real filesystem (front ends).
    case live
    /// Fresh machine: no config file.
    case missing
    /// File exists but does not parse/validate.
    case invalid
    /// Untouched starter template (placeholder repo).
    case template
    /// A caller-supplied parsed config (template-ness is detected from its repo).
    case loaded(KinhinConfig)
}

/// Internal, fully-resolved view of the scenario — no filesystem at evaluation time.
enum ConfigEvaluation {
    case parsed(KinhinConfig)
    case templateConfig
    case invalidFile
    case noFile
}
