import Foundation

// Row builders and config resolution used by `compute()`. They take their
// inputs as arguments (no probes), so tests call them directly.
extension SetupStatusComputer {
    /// The shared toolchain cache row: green when usable (or when it simply
    /// isn't needed yet), red-but-advisory only when `share_cache` is on and
    /// the host directory is missing/unwritable — that combination would
    /// leave every runner's cache mounts silently empty.
    static func toolchainCacheCheck(usable: Bool, shareCacheOn: Bool) -> SetupCheckResult {
        if usable {
            return SetupCheckResult(
                id: "toolchain-cache",
                title: "Shared toolchain cache",
                ok: true,
                detail: shareCacheOn
                    ? "host cache ready — runner VMs and containers mount it (share_cache on)"
                    : "host cache ready — `share_cache: true` also mounts it into runners",
                action: nil
            )
        }
        return SetupCheckResult(
            id: "toolchain-cache",
            title: "Shared toolchain cache",
            ok: true,  // advisory: a missing cache never blocks onboarding
            detail: shareCacheOn
                ? "host cache directory missing — runner mounts will be empty until the next prepare recreates it"
                : "not created yet — the next `kinhin image prepare` creates it",
            action: shareCacheOn ? "create_toolchain_cache" : nil
        )
    }

    /// The provision-script row: green when the configured script exists and
    /// is non-empty — exactly what `image prepare` will validate — otherwise
    /// a fix row pointing at config.yaml. Only called for configs that
    /// declare `provision_script`.
    static func provisionScriptCheck(_ cfg: KinhinConfig) -> SetupCheckResult {
        func broken(_ detail: String) -> SetupCheckResult {
            SetupCheckResult(
                id: "provision-script",
                title: "Provision script",
                ok: false,
                detail: detail,
                action: "repair_provision_script"
            )
        }
        do {
            let resolved = try ImagePreparer.resolveProvisionScript(cfg.provisionScript)
            return SetupCheckResult(
                id: "provision-script",
                title: "Provision script",
                ok: true,
                detail: "script found: \(resolved?.path ?? "")",
                action: nil
            )
        } catch let error as ImageError {
            guard case .provisionScriptUnreadable(let path, let reason) = error else {
                return broken("\(cfg.provisionScript ?? "") (unusable)")
            }
            if reason == "script is empty" {
                return broken("\(path) is empty — add commands or remove provision_script from config.yaml")
            }
            return broken("missing or unreadable at \(path) — fix the path in config.yaml")
        } catch {
            return broken("\(cfg.provisionScript ?? "") (unusable: \(error))")
        }
    }

    /// The full config row, total over every evaluation state: working config
    /// (ok), untouched template (created — needs your repo, Edit Config),
    /// invalid file, or missing (Create Config).
    static func configCheck(_ evaluation: ConfigEvaluation, path: String) -> SetupCheckResult {
        switch evaluation {
        case .parsed(let cfg):
            let scope =
                cfg.accounts.isEmpty
                ? "no accounts yet"
                : cfg.accounts.map { account -> String in
                    var text = "\(account.name): \(account.scope)"
                    if let instance = account.instance, !instance.isEmpty {
                        text += " @ \(instance)"
                    }
                    return text
                }.joined(separator: ", ")
            return SetupCheckResult(
                id: "config",
                title: "Config created",
                ok: true,
                detail: "\(scope) · labels: \(cfg.labels.joined(separator: ","))",
                action: nil
            )
        case .templateConfig:
            return SetupCheckResult(
                id: "config",
                title: "Config created",
                ok: false,
                detail: "template created — add an account in \(path)",
                action: "edit_config"
            )
        case .invalidFile:
            return SetupCheckResult(
                id: "config",
                title: "Config created",
                ok: false,
                detail: "\(path) (invalid)",
                action: "create_config"
            )
        case .noFile:
            return SetupCheckResult(
                id: "config",
                title: "Config created",
                ok: false,
                detail: "not created yet",
                action: "create_config"
            )
        }
    }

    /// Scenario → evaluation. `.live` probes the real filesystem (and
    /// classifies a parsed file as template vs working); every other case
    /// maps directly to its evaluation.
    static func resolve(_ config: ConfigScenario) -> ConfigEvaluation {
        switch config {
        case .live:
            if let cfg = liveConfig() {
                return ConfigLoader.hasAnyForge(cfg) ? .parsed(cfg) : .templateConfig
            }
            return FileManager.default.fileExists(atPath: Paths.config.path) ? .invalidFile : .noFile
        case .missing:
            return .noFile
        case .invalid:
            return .invalidFile
        case .template:
            return .templateConfig
        case .loaded(let cfg):
            return ConfigLoader.hasAnyForge(cfg) ? .parsed(cfg) : .templateConfig
        }
    }
}
