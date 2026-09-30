import Foundation

/// Builds GitHub API clients for the engine. Injectable in tests; the
/// production instance rebuilds clients when the user replaces their PAT so
/// the swap takes effect without restarting the engine.
public struct GitHubClientFactory: Sendable {
    public var make: @Sendable (GitHubCredentials) -> GitHubServing

    public init(make: @escaping @Sendable (GitHubCredentials) -> GitHubServing) {
        self.make = make
    }

    /// Production factory: real GitHubClient instances.
    public static var live: GitHubClientFactory {
        GitHubClientFactory { GitHubClient(credentials: $0) }
    }
}
