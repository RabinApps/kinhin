import Foundation

// MARK: - Descriptor

/// Everything that differs per forge and is not part of the runtime `Forge`
/// adapter: how the forge names itself, what a valid scope looks like, how
/// its `accounts:` entry is parsed, the runner agent it needs, how its token
/// is checked, how its `Forge` is built, and the registration script it runs
/// in each guest.
///
/// This is the one place the per-forge facts live. `ForgeID.descriptor` is the
/// single exhaustive switch; every site that used to switch on the forge
/// (image bakes, the host installer, registration scripts, token health,
/// engine attach, config parsing) now asks the descriptor instead. Adding a
/// forge is therefore one `<Name>Descriptor` conformance plus one case below;
/// see `docs/adding-a-forge.md`.
protocol ForgeDescriptor: Sendable {
    var id: ForgeID { get }
    /// The product name for UI and messages ("GitHub", "GitLab", …).
    var displayName: String { get }
    /// Whether the user hosts the server, so an account may name an
    /// `instance` and opt into plain http.
    var isSelfHosted: Bool { get }
    /// What a valid `scope:` looks like, for error messages.
    var scopeHint: String { get }
    /// Whether `scope` is accepted by this forge's grammar.
    func isValidScope(_ scope: String) -> Bool
    /// Whether `scope` names one repository on a forge whose runners register
    /// per repository (orgs, groups, clusters and pools cover many).
    func isSingleRepositoryScope(_ scope: String) -> Bool
    /// Validates one `accounts:` entry (after the checks every forge shares)
    /// and builds its `AccountConfig`.
    func parseAccount(_ entry: ConfigLoader.AccountEntry) throws -> AccountConfig
}

extension ForgeDescriptor {
    /// `owner/name` is one repository; a bare org name is not.
    func isSingleRepositoryScope(_ scope: String) -> Bool {
        scope.split(separator: "/", omittingEmptySubsequences: false).count == 2
    }
}

extension ForgeID {
    /// The descriptor for this forge. The switch is exhaustive on purpose,
    /// with no `default`: a new forge cannot compile until it has one.
    var descriptor: any ForgeDescriptor {
        switch self {
        case .github: return GitHubDescriptor()
        case .gitlab: return GitLabDescriptor()
        case .gitea: return GiteaDescriptor(id: .gitea)
        case .forgejo: return GiteaDescriptor(id: .forgejo)
        case .buildkite: return BuildkiteDescriptor()
        case .azuredevops: return AzureDevOpsDescriptor()
        case .bitbucket: return BitbucketDescriptor()
        }
    }

    /// The product name for UI and messages ("GitHub", "GitLab", …).
    public var displayName: String { descriptor.displayName }

    /// Forges whose server the user hosts, so the account may name an
    /// `instance` and may opt into plain http.
    var isSelfHosted: Bool { descriptor.isSelfHosted }

    /// What a valid `scope:` looks like on this forge, for error messages.
    var scopeHint: String { descriptor.scopeHint }
}
