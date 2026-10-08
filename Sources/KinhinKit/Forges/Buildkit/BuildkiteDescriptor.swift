import Foundation

struct BuildkiteDescriptor: ForgeDescriptor {
    let id: ForgeID = .buildkite
    let displayName = "Buildkite"
    let isSelfHosted = false
    let scopeHint = "'org-slug/cluster' (the cluster's name or id)"

    func isValidScope(_ scope: String) -> Bool { BuildkiteCredentials.isValidScope(scope) }

    /// A cluster covers many repositories.
    func isSingleRepositoryScope(_ scope: String) -> Bool { false }

    func parseAccount(_ entry: ConfigLoader.AccountEntry) throws -> AccountConfig {
        try ConfigLoader.parseBuildkiteAccount(entry)
    }
}
