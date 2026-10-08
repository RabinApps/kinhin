import Foundation

struct AzureDevOpsDescriptor: ForgeDescriptor {
    let id: ForgeID = .azuredevops
    let displayName = "Azure DevOps"
    let isSelfHosted = true
    let scopeHint = "the agent pool's name"

    func isValidScope(_ scope: String) -> Bool { AzureDevOpsCredentials.isValidScope(scope) }

    /// A pool covers many repositories.
    func isSingleRepositoryScope(_ scope: String) -> Bool { false }

    func parseAccount(_ entry: ConfigLoader.AccountEntry) throws -> AccountConfig {
        try ConfigLoader.parseAzureDevOpsAccount(entry)
    }
}
