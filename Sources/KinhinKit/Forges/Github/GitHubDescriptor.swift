import Foundation

struct GitHubDescriptor: ForgeDescriptor {
    let id: ForgeID = .github
    let displayName = "GitHub"
    let isSelfHosted = false
    let scopeHint = "'owner/name' or an org name"

    func isValidScope(_ scope: String) -> Bool { AccountConfig.isValidScope(scope) }

    func parseAccount(_ entry: ConfigLoader.AccountEntry) throws -> AccountConfig {
        try ConfigLoader.parseGitHubAccount(entry)
    }
}
