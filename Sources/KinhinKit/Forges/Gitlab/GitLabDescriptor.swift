import Foundation

struct GitLabDescriptor: ForgeDescriptor {
    let id: ForgeID = .gitlab
    let displayName = "GitLab"
    let isSelfHosted = true
    let scopeHint = "a GitLab project or group path (e.g. 'group/project')"

    func isValidScope(_ scope: String) -> Bool { GitLabCredentials.isValidScope(scope) }

    /// GitLab paths nest; only a project path (group/project) names one project,
    /// and it is indistinguishable from a subgroup, so require two or more segments.
    func isSingleRepositoryScope(_ scope: String) -> Bool { scope.split(separator: "/").count >= 2 }

    func parseAccount(_ entry: ConfigLoader.AccountEntry) throws -> AccountConfig {
        try ConfigLoader.parseGitLabAccount(entry)
    }
}
