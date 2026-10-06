import Foundation
import KinhinKit

@discardableResult
func noteAutoCreatedConfigIfMissing() -> Bool {
    if ConfigLoader.createIfMissing() {
        FileHandle.standardError.write(
            Data(
                "note: created starter config at \(Paths.config.path) — set your repo, then run `kinhin auth set`\n"
                    .utf8))
        return true
    }
    return false
}

/// After `auth set` saves a token, tell a running daemon so the swap is live
/// immediately (otherwise it would keep the old token until restart).
/// Best-effort: no daemon is not an error.
func notifyDaemonTokenReplaced(_ target: CredentialRotation.Target, token: String) {
    guard RPCClient.isDaemonAlive() else { return }
    do {
        try CredentialRotation.notify(target, token: token, daemon: RPCClient())
        if case .account(let name) = target {
            print("running daemon notified — new token for '\(name)' is live")
        } else {
            print("running daemon notified — new token is live")
        }
    } catch {
        warn("could not notify running daemon (\(error.localizedDescription)); restart it to pick up the new token")
    }
}

/// The config for a housekeeping command (`image list`, `image delete`): a
/// broken config degrades to the defaults with a warning — the command may be
/// run precisely because the config is broken. `cleanup` says the same thing
/// in its own wording (it names the file it could not read).
func loadConfigLeniently() -> KinhinConfig {
    do {
        return try ConfigLoader.load()
    } catch {
        warn("could not read the config (\(error.localizedDescription)); using the defaults")
        return KinhinConfig.default
    }
}

func loadConfigOrExit() -> KinhinConfig {
    do {
        let cfg = try ConfigLoader.load()
        return cfg
    } catch {
        fail(error)
    }
}

/// The token the engine is built with: the GitHub PAT, or an empty
/// placeholder for a Gitea-only config (whose own token is required instead).
func tokenOrExit(for cfg: KinhinConfig) -> String {
    let stored: String?
    do {
        stored = try ConfigLoader.engineToken(for: cfg)
    } catch {
        fail(error.localizedDescription, exit: .auth)
    }
    guard let token = stored else {
        fail(
            cfg.githubEnabled
                ? "no GitHub token stored. Run: kinhin auth set"
                : cfg.gitea != nil
                    ? "no Gitea token stored. Run: kinhin auth set --gitea"
                    : "no account has a token stored. See: kinhin auth list, then kinhin auth set --account NAME",
            exit: .auth)
    }
    return token
}

func engineFromConfig(_ cfg: KinhinConfig) throws -> FleetEngine {
    // The auto-created template parses cleanly but names a placeholder repo —
    // never boot a fleet (and start polling GitHub) against it.
    if !ConfigLoader.hasAnyForge(cfg) {
        fail(
            "config has no forge yet — set your repo (or a gitea: section) in \(Paths.config.path) first",
            exit: .config)
    }
    return try FleetEngine.production(config: cfg, token: tokenOrExit(for: cfg))
}
