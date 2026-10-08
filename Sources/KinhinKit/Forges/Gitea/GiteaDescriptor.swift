import Foundation

/// Gitea and Forgejo: wire-compatible, so one descriptor serves both and only
/// the id (and with it the display name) differs.
struct GiteaDescriptor: ForgeDescriptor {
    let id: ForgeID
    var displayName: String { id == .forgejo ? "Forgejo" : "Gitea" }
    let isSelfHosted = true
    let scopeHint = "'owner/name' or an org name"

    func isValidScope(_ scope: String) -> Bool { AccountConfig.isValidScope(scope) }

    func parseAccount(_ entry: ConfigLoader.AccountEntry) throws -> AccountConfig {
        try ConfigLoader.parseGiteaAccount(entry)
    }
}
