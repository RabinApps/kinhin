import Foundation

// MARK: - Admin client

/// The forge-agnostic admin surface the settings forms and `auth status` use:
/// verify a token and list what it can see. Built per account by
/// `ForgeDescriptor.makeAdmin(account:token:)`, so `TokenHealthCheck` never
/// switches on the forge or holds per-forge client types.
protocol ForgeAdmin: Sendable {
    /// The same mint-registration-token style probe the engine's startup gate
    /// uses, reported as a user-facing verdict. Registers nothing.
    func checkToken() async -> TokenHealthCheck.Report
    /// The scopes the token can see (repositories, clusters, pools, workspaces).
    func listScopes() async throws -> [RepoRef]
}

/// A `ForgeAdmin` assembled from two closures, which is all any forge needs.
struct ClosureForgeAdmin: ForgeAdmin {
    let check: @Sendable () async -> TokenHealthCheck.Report
    let scopes: @Sendable () async throws -> [RepoRef]

    func checkToken() async -> TokenHealthCheck.Report { await check() }
    func listScopes() async throws -> [RepoRef] { try await scopes() }
}

// MARK: - Forge construction

/// What `ForgeDescriptor.makeForge(_:)` needs from the engine to build and
/// verify one account's `Forge`. The closures are the parts that only the
/// engine owns (its GitHub client factory and scale-set listener wiring).
struct ForgeBuild {
    let account: AccountConfig
    let token: String
    /// Verify the token against the forge while building (GitHub's org
    /// permission probe; the other forges verify inside their `make`).
    let verify: Bool
    /// The top-level `labels:` accounts fall back to.
    let fleetLabels: [String]
    /// Every label some pool of the fleet registers runners with (fleet labels
    /// plus runtime markers, container and image labels). GitLab matches a job
    /// when its tags are a subset of a runner's, so this is its demand filter.
    let poolLabels: [String]
    /// The config's `min_runners`, a demand floor for Gitea-family forges.
    let minRunners: Int
    let githubClient: (GitHubCredentials) -> GitHubServing
    let scaleSetTargets: (GitHubServing, AccountConfig.ScaleSetConfig) async -> [ScaleSetTarget]
}
