import Foundation

struct BitbucketDescriptor: ForgeDescriptor {
    let id: ForgeID = .bitbucket
    let displayName = "Bitbucket"
    let isSelfHosted = false
    let scopeHint = "a workspace slug, or 'workspace/repo-slug' for one repository"

    func isValidScope(_ scope: String) -> Bool { BitbucketCredentials.isValidScope(scope) }

    func parseAccount(_ entry: ConfigLoader.AccountEntry) throws -> AccountConfig {
        try ConfigLoader.parseBitbucketAccount(entry)
    }
}
