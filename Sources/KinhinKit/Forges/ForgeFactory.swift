import Foundation

// MARK: - Forge factory

/// Builds Forge instances from credentials. Injectable in tests; production
/// wiring returns the platform clients.
struct ForgeFactory: Sendable {
    public var make: @Sendable (ForgeCredentials, [String], Int) async throws -> Forge

    public init(make: @escaping @Sendable (ForgeCredentials, [String], Int) async throws -> Forge) {
        self.make = make
    }

    public static var live: ForgeFactory {
        ForgeFactory { credentials, labels, floor in
            switch credentials {
            case .github:
                return GitHubForge(
                    credentials: credentials, labels: labels,
                    client: GitHubClient(
                        credentials: GitHubCredentials(token: token(of: credentials), scope: scope(of: credentials))))
            case .gitea(let token, let scope, let instance):
                let gitea = GiteaCredentials(token: token, scope: scope, instance: instance)
                return try await GiteaForge.make(credentials: gitea, labels: labels, demandFloor: floor)
            case .forgejo(let token, let scope, let instance):
                let forgejo = GiteaCredentials(token: token, scope: scope, instance: instance)
                return try await ForgejoForge.make(credentials: forgejo, labels: labels, demandFloor: floor)
            }
        }
    }

    static func token(of credentials: ForgeCredentials) -> String {
        switch credentials {
        case .github(let token, _): return token
        case .gitea(let token, _, _): return token
        case .forgejo(let token, _, _): return token
        }
    }

    static func scope(of credentials: ForgeCredentials) -> String {
        switch credentials {
        case .github(_, let scope): return scope
        case .gitea(_, let scope, _): return scope
        case .forgejo(_, let scope, _): return scope
        }
    }
}
